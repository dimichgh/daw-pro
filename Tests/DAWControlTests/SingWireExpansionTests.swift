import Foundation
import Testing
@testable import AIServices
@testable import DAWControl
@testable import DAWCore

/// p2-sing-x7 part A (W8-X7A): the singing expansion's wire (design `docs/design/2026-10-06-p2-sing-expansion.md`
/// §3.4, §4.7, §5.6, §6.9, §8.1, §9.2 S6). Nonisolated: each test hops to the main actor for the store.
///
/// SPY tests stand a recorder in front of the SAME store methods the Sing sheet calls (`setNoteWord`,
/// `setClipLyrics(…language:…)`, `setSingStyle`), so a handler that writes around them goes red.
@Suite("SingWire expansion — note words, language, wordless, singing style, harmony, capabilities (p2-sing-x7)")
struct SingWireExpansionTests {

    // MARK: - Rig

    struct Rig {
        let router: CommandRouter
        let store: ProjectStore
        let clipID: UUID
        let lyricsSpy: SingWireLyricsSpy
        let editSpy: SingWireEditSpy
        let styleSpy: SingWireStyleSpy
    }

    private func rig(lyrics: String? = nil, onsets: [Double] = SingWireFixture.twoUnitOnsets,
                     pitches: [Int] = SingWireFixture.twoUnitPitches) async throws -> Rig {
        let root = try SingWireFixture.tempDir("x7a")
        return try await MainActor.run {
            let (store, clipID) = try SingWireFixture.store(root: root, lyrics: lyrics, onsets: onsets, pitches: pitches)
            let lyricsSpy = SingWireLyricsSpy(store: store)
            let editSpy = SingWireEditSpy(store: store)
            let styleSpy = SingWireStyleSpy(store: store)
            let router = CommandRouter(store: store, singLyrics: lyricsSpy, singLyricsEditing: editSpy,
                                       singStyle: styleSpy)
            return Rig(router: router, store: store, clipID: clipID, lyricsSpy: lyricsSpy, editSpy: editSpy,
                       styleSpy: styleSpy)
        }
    }

    private func call(_ rig: Rig, _ command: String, _ params: [String: JSONValue]) async -> ControlResponse {
        await rig.router.handle(SingWireFixture.request(command, params))
    }

    private func clip(_ rig: Rig) async -> Clip? {
        await MainActor.run { rig.store.tracks.flatMap(\.clips).first { $0.id == rig.clipID } }
    }

    private func noteIDs(_ rig: Rig) async -> [UUID] {
        await MainActor.run {
            MIDINote.canonicallyOrdered(rig.store.tracks.flatMap(\.clips).first { $0.id == rig.clipID }?.notes ?? [])
                .map(\.id)
        }
    }

    private func audioClip(_ rig: Rig) async throws -> UUID {
        try await MainActor.run { () -> UUID in
            let track = rig.store.addTrack(kind: .audio)
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent("x7a-\(UUID()).wav")
            try SingWAV.writeFloat32Mono([Float](repeating: 0, count: 4_800), sampleRate: 48_000, to: wav)
            return try rig.store.importAudio(url: wav, toTrack: track.id, atBeat: 0).id
        }
    }

    private func emptyMIDIClip(_ rig: Rig) async throws -> UUID {
        try await MainActor.run { () -> UUID in
            let track = rig.store.addTrack(kind: .instrument)
            return try rig.store.addMIDIClip(toTrack: track.id, name: "Empty", atBeat: 0, lengthBeats: 4, notes: []).id
        }
    }

    // MARK: - clip.setNoteWord (§3.4)

    @Test("SPY: clip.setNoteWord reaches setNoteWord once with its params; the old lyrics seam is never used")
    func setNoteWordReachesSetNoteWord() async throws {
        let rig = try await self.rig(lyrics: SingWireFixture.twoUnitLyrics)
        let notes = await noteIDs(rig)
        let response = await call(rig, "clip.setNoteWord", ["clipId": .string(rig.clipID.uuidString),
                                                             "noteId": .string(notes[1].uuidString),
                                                             "word": .string("deux")])
        #expect(response.ok, "\(response.error ?? "")")
        let calls = await MainActor.run { rig.editSpy.noteWordCalls }
        #expect(calls == [.init(clipId: rig.clipID, noteId: notes[1], word: "deux", dryRun: false)])
        #expect(await MainActor.run { rig.lyricsSpy.calls.isEmpty }, "no write around setNoteWord")
        #expect(response.result?["stored"]?.boolValue == true)
        #expect(response.result?["changed"]?.boolValue == true)
        let words = response.result?["assignment"]?["words"]?.arrayValue ?? []
        #expect(words.count == 8)
        #expect(words.dropFirst().first?["text"]?.stringValue == "deux")
        #expect(Set(response.result.map { Set($0.objectValue?.keys.map { $0 } ?? []) } ?? [])
            == ["clipId", "text", "stored", "changed", "assignment", "warnings"])
        let stored = await clip(rig)?.lyrics?.text
        #expect(stored == response.result?["text"]?.stringValue)
        #expect(try await MainActor.run { try rig.store.undo() } == "Type Word")
        #expect(await clip(rig)?.lyrics?.text == SingWireFixture.twoUnitLyrics)
    }

    @Test("clip.setNoteWord dryRun answers the same and stores nothing")
    func setNoteWordDryRun() async throws {
        let rig = try await self.rig(lyrics: SingWireFixture.twoUnitLyrics)
        let notes = await noteIDs(rig)
        let response = await call(rig, "clip.setNoteWord", ["clipId": .string(rig.clipID.uuidString),
                                                             "noteId": .string(notes[2].uuidString),
                                                             "word": .string("trois"), "dryRun": .bool(true)])
        #expect(response.ok, "\(response.error ?? "")")
        #expect(response.result?["stored"]?.boolValue == false)
        #expect(await MainActor.run { rig.editSpy.noteWordCalls.map(\.dryRun) } == [true])
        #expect(await clip(rig)?.lyrics?.text == SingWireFixture.twoUnitLyrics)
    }

    @Test("clip.setNoteWord: every refusal reads \"<code>: <sentence>\" exactly (§3.4/§14 verbatim) and writes nothing")
    func setNoteWordRefusals() async throws {
        let rig = try await self.rig(lyrics: SingWireFixture.twoUnitLyrics)
        let notes = await noteIDs(rig)
        let audio = try await audioClip(rig)
        let bare = try await self.rig()
        let bareNotes = await noteIDs(bare)
        let unknown = UUID()
        let clip = rig.clipID.uuidString
        let cases: [(Rig, [String: JSONValue], String)] = [
            (rig, ["clipId": .string(unknown.uuidString), "noteId": .string(notes[0].uuidString), "word": .string("a")],
             "clipNotFound: no clip with id \(unknown.uuidString) — use project.snapshot to list clips"),
            (rig, ["clipId": .string(audio.uuidString), "noteId": .string(notes[0].uuidString), "word": .string("a")],
             "lyricsNeedMIDIClip: Sing needs a melody clip with notes. This one is audio."),
            (bare, ["clipId": .string(bare.clipID.uuidString), "noteId": .string(bareNotes[0].uuidString),
                    "word": .string("a")],
             "lyricsNoText: Type the words in the box first; then you can change single notes."),
            (rig, ["clipId": .string(clip), "noteId": .string(unknown.uuidString), "word": .string("a")],
             "noteNotFound: I couldn't find that note in this clip."),
            (rig, ["clipId": .string(clip), "noteId": .string(notes[1].uuidString), "word": .string("two words")],
             "lyricWordHasSpace: Type one word per note. To type several, use the words box."),
            (rig, ["clipId": .string(clip), "noteId": .string(notes[1].uuidString), "word": .string("star+")],
             "lyricWordHasMarks: Type the word without + marks. To hold the word before onto this note, type just +."),
            (rig, ["clipId": .string(clip), "noteId": .string(notes[4].uuidString), "word": .string("+")],
             "lyricNothingToHold: This note starts a new line of the tune, so there's no word before it to hold. "
                + "Type a word instead."),
            (rig, ["clipId": .string(clip), "noteId": .string(notes[1].uuidString), "word": .string("a"),
                   "lang": .string("en")],
             "clip.setNoteWord: unknown parameter 'lang' — valid keys are 'clipId', 'dryRun', 'noteId', 'word'. "
                + "to write a whole line at once, use clip.setLyrics"),
        ]
        for (r, params, expected) in cases {
            for dryRun in [false, true] {
                var p = params
                p["dryRun"] = .bool(dryRun)
                if p["lang"] != nil { p["dryRun"] = nil }
                let response = await call(r, "clip.setNoteWord", p)
                #expect(!response.ok)
                #expect(response.error == expected, "dryRun \(dryRun)")
            }
        }
        #expect(await self.clip(rig)?.lyrics?.text == SingWireFixture.twoUnitLyrics)
        #expect(await self.clip(bare)?.lyrics == nil)
    }

    @Test("clip.setNoteWord: a chord note the one-at-a-time rule drops is refused noteNotSung (§14 verbatim)")
    func setNoteWordNoteNotSung() async throws {
        // A chord at beat 4: the higher note sings, the lower one does not.
        let rig = try await self.rig(lyrics: "one two three four", onsets: [4, 4, 5, 6, 7], pitches: [64, 55, 65, 67, 69])
        let low = try #require(await MainActor.run {
            rig.store.tracks.flatMap(\.clips).first { $0.id == rig.clipID }?.notes?.first { $0.pitch == 55 }?.id
        })
        let response = await call(rig, "clip.setNoteWord", ["clipId": .string(rig.clipID.uuidString),
                                                             "noteId": .string(low.uuidString), "word": .string("x")])
        #expect(response.error
            == "noteNotSung: This note isn't sung: it is part of a chord, or no words reach this line yet.")
        #expect(await clip(rig)?.lyrics?.text == "one two three four")
    }

    // MARK: - clip.setLyrics {language} (§6.9)

    @Test("SPY: clip.setLyrics with language reaches setClipLyrics(…language:…); without it, the base seam, and the clip keeps its language")
    func setLyricsLanguageReachesLanguageOverload() async throws {
        let rig = try await self.rig()
        let zh = "一二三四\n五六七八"
        let set = await call(rig, "clip.setLyrics", ["clipId": .string(rig.clipID.uuidString), "text": .string(zh),
                                                     "language": .string("zh")])
        #expect(set.ok, "\(set.error ?? "")")
        #expect(await MainActor.run { rig.editSpy.lyricsCalls }
            == [.init(clipId: rig.clipID, text: zh, language: "zh", undoLabel: "Set Lyrics")])
        #expect(await MainActor.run { rig.lyricsSpy.calls.isEmpty })
        #expect(set.result?["language"]?.stringValue == "zh")
        #expect(set.result?["assignment"]?["words"]?.arrayValue?.count == 8)
        #expect(await clip(rig)?.lyrics?.language == "zh")

        // Text only on the Chinese clip: checked AS Chinese (not refused as a script mismatch), stored through the
        // base seam, the language kept, and no `language` key in the reply.
        let again = "九十一二\n三四五六"
        let textOnly = await call(rig, "clip.setLyrics", ["clipId": .string(rig.clipID.uuidString),
                                                          "text": .string(again)])
        #expect(textOnly.ok, "\(textOnly.error ?? "")")
        #expect(await MainActor.run { rig.lyricsSpy.calls.map(\.text) } == [again])
        #expect(textOnly.result?["language"] == nil)
        #expect(await clip(rig)?.lyrics?.language == "zh")
        #expect(await clip(rig)?.lyrics?.text == again)

        // A language-only change is an edit too; "en" is English, stored as no code.
        let back = await call(rig, "clip.setLyrics", ["clipId": .string(rig.clipID.uuidString),
                                                      "text": .string(SingWireFixture.twoUnitLyrics),
                                                      "language": .string("en")])
        #expect(back.ok, "\(back.error ?? "")")
        #expect(back.result?["language"]?.stringValue == "en")
        #expect(await clip(rig)?.lyrics?.language == nil)
        let same = await call(rig, "clip.setLyrics", ["clipId": .string(rig.clipID.uuidString),
                                                      "text": .string(SingWireFixture.twoUnitLyrics),
                                                      "language": .string("en")])
        #expect(same.result?["changed"]?.boolValue == false)
        #expect(await MainActor.run { rig.editSpy.lyricsCalls.count } == 2, "an unchanged write records no step")
    }

    @Test("clip.setLyrics: an unsupported language (Spanish is out) and Chinese typed into an English clip refuse with the store's codes, dry run too, writing nothing")
    func setLyricsLanguageRefusals() async throws {
        let rig = try await self.rig()
        let clip = JSONValue.string(rig.clipID.uuidString)
        let unsupported = "lyricsLanguageUnsupported: I can't sing in that language yet. Set Language to English, "
            + "Chinese (Mandarin) or Chinese (Cantonese)."
        let cases: [([String: JSONValue], String)] = [
            (["clipId": clip, "text": .string("uno dos tres cuatro"), "language": .string("es")], unsupported),
            (["clipId": clip, "text": .string(""), "language": .string("es")], unsupported),
            (["clipId": clip, "text": .string("one"), "language": .string("fr")], unsupported),
            (["clipId": clip, "text": .string("一二三四\nfive six seven eight")],
             "lyricsScriptMismatch: These look like Chinese characters. Set Language to Chinese (Mandarin) or Chinese "
                + "(Cantonese), and I'll sing them."),
            (["clipId": clip, "text": .string("one"), "language": .number(1)],
             "'language' must be a string: \"en\" (English), \"zh\" (Chinese, Mandarin) or \"yue\" (Chinese, Cantonese)"),
        ]
        for (params, expected) in cases {
            for dryRun in [false, true] {
                var p = params
                p["dryRun"] = .bool(dryRun)
                let response = await call(rig, "clip.setLyrics", p)
                #expect(!response.ok)
                #expect(response.error == expected, "dryRun \(dryRun)")
            }
        }
        #expect(await MainActor.run { rig.editSpy.lyricsCalls.isEmpty && rig.lyricsSpy.calls.isEmpty })
        #expect(await self.clip(rig)?.lyrics == nil)
    }

    @Test("clip.getLyrics carries language ONLY when the clip has one")
    func getLyricsLanguageOnlyWhenSet() async throws {
        let rig = try await self.rig(lyrics: SingWireFixture.twoUnitLyrics)
        let get = SingWireFixture.request("clip.getLyrics", ["clipId": .string(rig.clipID.uuidString)])
        let english = await rig.router.handle(get)
        #expect(english.ok)
        #expect(english.result?["language"] == nil)
        _ = await call(rig, "clip.setLyrics", ["clipId": .string(rig.clipID.uuidString),
                                               "text": .string("一二三四\n五六七八"), "language": .string("yue")])
        let chinese = await rig.router.handle(get)
        #expect(chinese.result?["language"]?.stringValue == "yue")
        #expect(chinese.result?["problem"] == .null)
    }

    // MARK: - clip.setLyrics {wordless} (§8.1)

    @Test("wordless writes one held sound per breath phrase, or one per note, through the base lyrics seam")
    func wordlessWritesText() async throws {
        let rig = try await self.rig()
        let line = await call(rig, "clip.setLyrics", ["clipId": .string(rig.clipID.uuidString),
                                                      "wordless": .string("ooh")])
        #expect(line.ok, "\(line.error ?? "")")
        #expect(line.result?["text"]?.stringValue == "ooh+++\nooh+++")
        let words = line.result?["assignment"]?["words"]?.arrayValue ?? []
        #expect(words.map { $0["noteIds"]?.arrayValue?.count ?? 0 } == [4, 4])
        #expect(await MainActor.run { rig.lyricsSpy.calls.map(\.text) } == ["ooh+++\nooh+++"])
        #expect(line.result?["language"] == nil)

        let perNote = await call(rig, "clip.setLyrics", ["clipId": .string(rig.clipID.uuidString),
                                                         "wordless": .string("aah"), "wordlessPerNote": .bool(true),
                                                         "dryRun": .bool(true)])
        #expect(perNote.ok, "\(perNote.error ?? "")")
        #expect(perNote.result?["text"]?.stringValue == "aah aah aah aah\naah aah aah aah")
        #expect(perNote.result?["assignment"]?["words"]?.arrayValue?.count == 8)
        #expect(perNote.result?["stored"]?.boolValue == false)

        let hum = await call(rig, "clip.setLyrics", ["clipId": .string(rig.clipID.uuidString),
                                                     "wordless": .string("mm"), "dryRun": .bool(true)])
        #expect(hum.ok, "\(hum.error ?? "")")
        #expect(hum.result?["text"]?.stringValue == "mm+++\nmm+++")
    }

    @Test("wordless refusals: with text, an unknown sound, wordlessPerNote alone, a clip with no notes")
    func wordlessRefusals() async throws {
        let rig = try await self.rig()
        let empty = try await emptyMIDIClip(rig)
        let clip = JSONValue.string(rig.clipID.uuidString)
        let cases: [([String: JSONValue], String)] = [
            (["clipId": clip, "wordless": .string("ooh"), "text": .string("la")],
             "lyricsWordlessWithText: Send either text or wordless, not both: wordless writes the words for you."),
            (["clipId": clip, "wordless": .string("la")], "lyricsWordlessInvalid: wordless can be ooh, aah or mm."),
            (["clipId": clip, "text": .string("la"), "wordlessPerNote": .bool(true)],
             "lyricsWordlessPerNoteAlone: wordlessPerNote goes with wordless: send wordless too (ooh, aah or mm)."),
            (["clipId": .string(empty.uuidString), "wordless": .string("ooh")],
             "singClipHasNoNotes: " + SingPlanRefusal.noNotes.sentence),
        ]
        for (params, expected) in cases {
            let response = await call(rig, "clip.setLyrics", params)
            #expect(response.error == expected)
        }
        #expect(await MainActor.run { rig.lyricsSpy.calls.isEmpty && rig.editSpy.lyricsCalls.isEmpty })
    }

    // MARK: - S6: without the new params, every reply is the pin-before reply

    @Test("S6: clip.setLyrics / clip.getLyrics without the new params reply byte-for-byte as before x7 (pinned on the unchanged tree)")
    func s6LyricsRepliesUnchanged() async throws {
        let root = try SingWireFixture.tempDir("x7a-s6")
        let (store, clipID, router) = try await MainActor.run { () -> (ProjectStore, UUID, CommandRouter) in
            let (store, clipID) = try SingWireFixture.store(root: root)
            return (store, clipID, CommandRouter(store: store))
        }
        func call(_ command: String, _ params: [String: JSONValue]) async -> ControlResponse {
            await router.handle(SingWireFixture.request(command, params))
        }
        let clip = JSONValue.string(clipID.uuidString)
        let lyrics = JSONValue.string(SingWireFixture.twoUnitLyrics)
        let a = await call("clip.setLyrics", ["clipId": clip, "text": lyrics, "dryRun": .bool(true)])
        #expect(try X7APin.canonical(a.result) == X7APin.setLyricsDryRun)
        let b = await call("clip.setLyrics", ["clipId": clip, "text": lyrics])
        #expect(try X7APin.canonical(b.result) == X7APin.setLyricsStore)
        let c = await call("clip.setLyrics", ["clipId": clip, "text": lyrics])
        #expect(try X7APin.canonical(c.result) == X7APin.setLyricsUnchanged)
        let d = await call("clip.getLyrics", ["clipId": clip])
        #expect(try X7APin.canonical(d.result) == X7APin.getLyrics)
        let held = await call("clip.setLyrics", ["clipId": clip, "text": .string("one two three\nfive six seven eight"),
                                                  "dryRun": .bool(true)])
        #expect(try X7APin.canonical(held.result) == X7APin.setLyricsHeldDryRun)
        let missing = await call("clip.setLyrics", ["clipId": clip])
        #expect(missing.error == X7APin.setLyricsMissingText)
        try await MainActor.run {
            let current = try #require(store.tracks.flatMap(\.clips).first { $0.id == clipID })
            _ = try store.setClipNotes(clipID: clipID, notes: Array((current.notes ?? []).prefix(4)))
        }
        let e = await call("clip.getLyrics", ["clipId": clip])
        #expect(try X7APin.canonical(e.result) == X7APin.getLyricsProblem)
        let (bare, bareClip) = try await MainActor.run { () -> (CommandRouter, UUID) in
            let (s2, c2) = try SingWireFixture.store(root: root)
            return (CommandRouter(store: s2), c2)
        }
        let f = await bare.handle(SingWireFixture.request("clip.getLyrics", ["clipId": .string(bareClip.uuidString)]))
        #expect(try X7APin.canonical(f.result) == X7APin.getLyricsNone)
    }

    @Test("S6: mixer.applyPreset's ONLY delta is the always-present removedSidechainKeys ([] here); everything else is the pin-before reply")
    func s6MixerApplyPresetOnlyDelta() async throws {
        let root = try SingWireFixture.tempDir("x7a-s6-mixer")
        let (store, router) = try await MainActor.run { () -> (ProjectStore, CommandRouter) in
            let (store, _) = try SingWireFixture.store(root: root)
            return (store, CommandRouter(store: store))
        }
        let trackID = await MainActor.run { store.addTrack(kind: .audio).id }
        let g = await router.handle(SingWireFixture.request("mixer.applyPreset", [
            "trackId": .string(trackID.uuidString), "preset": .string("vocal-presence")]))
        #expect(g.ok, "\(g.error ?? "")")
        var fields = try #require(g.result?.objectValue)
        #expect(fields.removeValue(forKey: "removedSidechainKeys") == .array([]))
        #expect(try X7APin.canonical(.object(fields)) == X7APin.mixerApplyPreset)
    }

    @Test("mixer.applyPreset reports the sidechain key it removed, from the store's result")
    func mixerApplyPresetReportsRemovedKey() async throws {
        let root = try SingWireFixture.tempDir("x7a-mixer-key")
        let (store, router) = try await MainActor.run { () -> (ProjectStore, CommandRouter) in
            let (store, _) = try SingWireFixture.store(root: root)
            return (store, CommandRouter(store: store))
        }
        let (bass, kick, effect) = try await MainActor.run { () -> (UUID, UUID, EffectDescriptor) in
            let bass = store.addTrack(name: "Bass", kind: .audio).id
            let kick = store.addTrack(name: "Kick", kind: .audio).id
            let compressor = try store.addEffect(toTrack: bass, kind: .compressor)
            _ = try store.setSidechain(trackID: bass, effectID: compressor.id, sourceTrackID: kick)
            return (bass, kick, compressor)
        }
        let response = await router.handle(SingWireFixture.request("mixer.applyPreset", [
            "trackId": .string(bass.uuidString), "preset": .string("vocal-presence")]))
        #expect(response.ok, "\(response.error ?? "")")
        let keys = response.result?["removedSidechainKeys"]?.arrayValue ?? []
        #expect(keys.count == 1)
        #expect(keys.first?["effectId"]?.stringValue == effect.id.uuidString)
        #expect(keys.first?["kind"]?.stringValue == EffectDescriptor.Kind.compressor.rawValue)
        #expect(keys.first?["sourceTrackId"]?.stringValue == kick.uuidString)
        #expect(keys.first?["sourceTrackName"]?.stringValue == "Kick")
        let preset = try #require(MixerPresetCatalog.preset(named: "vocal-presence"))
        let expected = await MainActor.run {
            ProjectStore.removedSidechainKeyMessage(stripName: "Bass", kind: .compressor, sourceName: "Kick",
                                                    presetDisplayName: preset.displayName)
        }
        #expect(keys.first?["message"]?.stringValue == expected)
    }

    // MARK: - clip.setSingStyle / clip.getSingStyle (§5.6)

    @Test("SPY: clip.setSingStyle reaches setSingStyle once with the parsed edit; ONE undo step (engine spy + journal)")
    func setSingStyleReachesStoreOnce() async throws {
        let rig = try await self.rig()
        let notes = await noteIDs(rig)
        let engine = await MainActor.run { () -> X7AEngineSpy in
            let spy = X7AEngineSpy()
            rig.store.engine = spy
            return spy
        }
        let before = await MainActor.run { (rig.store.lastEditEvent?.seq ?? 0, engine.tracksDidChangeCount) }
        let response = await call(rig, "clip.setSingStyle", [
            "clipId": .string(rig.clipID.uuidString), "vibrato": .string("wide"), "air": .number(0.4),
            "followVelocity": .bool(true),
            "notes": .array([.object(["noteId": .string(notes[0].uuidString), "vibrato": .string("straight")])]),
        ])
        #expect(response.ok, "\(response.error ?? "")")
        let calls = await MainActor.run { rig.styleSpy.calls }
        #expect(calls == [.init(clipId: rig.clipID, edit: SingStyleEdit(
            vibrato: .wide, air: 0.4, followVelocity: true,
            notes: [NoteSingStyleEdit(noteID: notes[0], style: NoteSingStyle(vibrato: .straight))]))])
        let after = await MainActor.run { (rig.store.lastEditEvent, engine.tracksDidChangeCount) }
        #expect(after.0?.seq == before.0 + 1, "exactly one journaled edit")
        #expect(after.0?.label == "Set Singing Style")
        #expect(after.1 == before.1 + 1, "the engine heard about the tracks exactly once")
        let style = response.result?["style"]
        #expect(style?["vibrato"]?.stringValue == "wide")
        #expect(style?["air"]?.doubleValue == 0.4)
        #expect(style?["followVelocity"]?.boolValue == true)
        #expect(style?["notes"]?.arrayValue?.first?["vibrato"]?.stringValue == "straight")
        #expect(response.result?["changed"]?.boolValue == true)
        #expect(response.result?["orphanedNoteIds"]?.arrayValue == [])
        let stored = await clip(rig)?.singStyle
        #expect(stored?.vibrato == .wide && stored?.notes?[notes[0]]?.vibrato == .straight)
    }

    @Test("clip.setSingStyle is all or nothing: an unknown note id changes NOTHING (no write, no step, no engine call)")
    func setSingStyleAllOrNothing() async throws {
        let rig = try await self.rig()
        let notes = await noteIDs(rig)
        let engine = await MainActor.run { () -> X7AEngineSpy in
            let spy = X7AEngineSpy()
            rig.store.engine = spy
            return spy
        }
        let unknown = UUID()
        let seq = await MainActor.run { rig.store.lastEditEvent?.seq }
        let response = await call(rig, "clip.setSingStyle", [
            "clipId": .string(rig.clipID.uuidString), "vibrato": .string("normal"),
            "notes": .array([.object(["noteId": .string(notes[0].uuidString), "vibrato": .string("wide")]),
                             .object(["noteId": .string(unknown.uuidString), "vibrato": .string("gentle")])]),
        ])
        #expect(response.error == "noteNotFound: There is no note \(unknown.uuidString) in this clip, so nothing was "
            + "changed. Check the note ids with clip.getNotes.")
        #expect(await clip(rig)?.singStyle == nil)
        #expect(await MainActor.run { rig.store.lastEditEvent?.seq } == seq)
        #expect(await MainActor.run { engine.tracksDidChangeCount } == 0)
    }

    @Test("clip.setSingStyle refusals read \"<code>: <sentence>\" exactly and write nothing")
    func setSingStyleRefusals() async throws {
        let rig = try await self.rig()
        let audio = try await audioClip(rig)
        let unknown = UUID()
        let clip = JSONValue.string(rig.clipID.uuidString)
        let cases: [([String: JSONValue], String)] = [
            (["clipId": .string(unknown.uuidString), "vibrato": .string("wide")],
             "clipNotFound: no clip with id \(unknown.uuidString) — use project.snapshot to list clips"),
            (["clipId": .string(audio.uuidString), "vibrato": .string("wide")],
             "singStyleNeedsMIDIClip: Sing needs a melody clip with notes. This one is audio."),
            (["clipId": clip, "vibrato": .string("shaky")],
             "singStyleVibratoInvalid: 'shaky' isn't a vibrato choice. Pick one of: asSung, straight, gentle, normal, wide."),
            (["clipId": clip, "air": .number(1.5)],
             "singStyleAirOutOfRange: Air goes from 0 (none) to 1 (lots). Pick a number in that range."),
            (["clipId": clip, "air": .number(-0.1)],
             "singStyleAirOutOfRange: Air goes from 0 (none) to 1 (lots). Pick a number in that range."),
            (["clipId": clip, "clear": .bool(true), "vibrato": .string("wide")],
             "singStyleClearAlone: Clear removes the whole singing style, so send clear on its own, with no other changes."),
            (["clipId": clip],
             "nothingToChange: Nothing to change: choose a vibrato, an air amount, follow note loudness or single notes, "
                + "or send clear to remove the style."),
            (["clipId": clip, "vibrato": .string("wide"), "vibratto": .string("wide")],
             "clip.setSingStyle: unknown parameter 'vibratto' — valid keys are 'air', 'clear', 'clipId', "
                + "'followVelocity', 'notes', 'vibrato'. per-note choices go in 'notes' as [{noteId, vibrato?, air?}]"),
            (["clipId": clip, "notes": .array([.object(["noteId": .string(UUID().uuidString), "vibe": .string("x")])])],
             "notes[0]: unknown key 'vibe' — valid keys are 'air', 'noteId', 'vibrato'"),
        ]
        for (params, expected) in cases {
            let response = await call(rig, "clip.setSingStyle", params)
            #expect(response.error == expected)
        }
        #expect(await MainActor.run { rig.store.tracks.flatMap(\.clips).allSatisfy { $0.singStyle == nil } })
    }

    @Test("clip.setSingStyle on an open live loop's layer: per-note choices refused, clip-wide ones allowed")
    func setSingStyleLoopLayer() async throws {
        let rig = try await self.rig()
        let notes = await noteIDs(rig)
        await MainActor.run {
            let trackID = rig.store.tracks.first { $0.clips.contains { $0.id == rig.clipID } }!.id
            rig.store.loopDeck = LoopDeck(originBeat: 0, cycleBeats: 4, beatsPerBar: 4, lengthMode: .fixedBars,
                                          layers: [LoopLayer(trackID: trackID, clipID: rig.clipID, ordinal: 1)])
        }
        let perNote = await call(rig, "clip.setSingStyle", [
            "clipId": .string(rig.clipID.uuidString),
            "notes": .array([.object(["noteId": .string(notes[0].uuidString), "air": .number(0.5)])]),
        ])
        #expect(perNote.error == "singStyleLoopNotes: This clip is a loop that's still being recorded, and its notes "
            + "are rewritten on every pass. Choose a style for the whole clip now, or style single notes after you "
            + "finish looping.")
        let wide = await call(rig, "clip.setSingStyle", ["clipId": .string(rig.clipID.uuidString),
                                                         "vibrato": .string("gentle")])
        #expect(wide.ok, "\(wide.error ?? "")")
        #expect(await clip(rig)?.singStyle == SingStyle(vibrato: .gentle))
    }

    @Test("orphans: a choice whose note is gone is reported by clip.getSingStyle and removed by the next write")
    func singStyleOrphans() async throws {
        let rig = try await self.rig()
        let notes = await noteIDs(rig)
        let set = await call(rig, "clip.setSingStyle", [
            "clipId": .string(rig.clipID.uuidString),
            "notes": .array([.object(["noteId": .string(notes[0].uuidString), "vibrato": .string("wide")]),
                             .object(["noteId": .string(notes[1].uuidString), "air": .number(0)])]),
        ])
        #expect(set.ok, "\(set.error ?? "")")
        try await MainActor.run {
            let current = try #require(rig.store.tracks.flatMap(\.clips).first { $0.id == rig.clipID })
            _ = try rig.store.setClipNotes(clipID: rig.clipID, notes: (current.notes ?? []).filter { $0.id != notes[0] })
        }
        let get = SingWireFixture.request("clip.getSingStyle", ["clipId": .string(rig.clipID.uuidString)])
        let first = await rig.router.handle(get)
        #expect(first.result?["orphanedNoteIds"]?.arrayValue == [.string(notes[0].uuidString)])
        #expect(first.result?["style"]?["notes"]?.arrayValue?.count == 2, "inert, still stored until the next write")
        let write = await call(rig, "clip.setSingStyle", ["clipId": .string(rig.clipID.uuidString),
                                                          "followVelocity": .bool(true)])
        #expect(write.result?["orphanedNoteIds"]?.arrayValue == [.string(notes[0].uuidString)])
        #expect(write.result?["style"]?["notes"]?.arrayValue?.map { $0["noteId"]?.stringValue }
            == [notes[1].uuidString], "a per-note air of 0 is a real choice and stays")
        let second = await rig.router.handle(get)
        #expect(second.result?["orphanedNoteIds"]?.arrayValue == [])
    }

    @Test("clear removes the style in one step; an all-default style is stored as none; {noteId} alone follows the clip")
    func setSingStyleClearAndDefaults() async throws {
        let rig = try await self.rig()
        let notes = await noteIDs(rig)
        let none = await call(rig, "clip.setSingStyle", ["clipId": .string(rig.clipID.uuidString),
                                                         "air": .number(0), "followVelocity": .bool(false)])
        #expect(none.result?["style"] == .null)
        #expect(none.result?["changed"]?.boolValue == false)
        // W9-PICKS (round V): the default vibrato is Normal, so a named As sung is a real choice and is stored.
        let asSung = await call(rig, "clip.setSingStyle", ["clipId": .string(rig.clipID.uuidString),
                                                           "vibrato": .string("asSung"), "air": .number(0)])
        #expect(asSung.result?["style"]?["vibrato"]?.stringValue == "asSung")
        #expect(asSung.result?["changed"]?.boolValue == true)
        _ = await call(rig, "clip.setSingStyle", [
            "clipId": .string(rig.clipID.uuidString), "vibrato": .string("normal"),
            "notes": .array([.object(["noteId": .string(notes[2].uuidString), "vibrato": .string("wide")])])])
        let follow = await call(rig, "clip.setSingStyle", [
            "clipId": .string(rig.clipID.uuidString),
            "notes": .array([.object(["noteId": .string(notes[2].uuidString)])])])
        #expect(follow.result?["style"]?["notes"]?.arrayValue == [])
        #expect(await clip(rig)?.singStyle == SingStyle(vibrato: .normal))
        let clear = await call(rig, "clip.setSingStyle", ["clipId": .string(rig.clipID.uuidString),
                                                          "clear": .bool(true)])
        #expect(clear.result?["style"] == .null)
        #expect(clear.result?["changed"]?.boolValue == true)
        #expect(await clip(rig)?.singStyle == nil)
        #expect(try await MainActor.run { try rig.store.undo() } == "Set Singing Style")
        #expect(await clip(rig)?.singStyle == SingStyle(vibrato: .normal))
    }

    @Test("clip.getSingStyle: null for a clip with no style; clipNotFound exactly")
    func getSingStyleBasics() async throws {
        let rig = try await self.rig()
        let none = await call(rig, "clip.getSingStyle", ["clipId": .string(rig.clipID.uuidString)])
        #expect(none.ok)
        #expect(none.result?["style"] == .null)
        #expect(none.result?["orphanedNoteIds"]?.arrayValue == [])
        let unknown = UUID()
        let missing = await call(rig, "clip.getSingStyle", ["clipId": .string(unknown.uuidString)])
        #expect(missing.error == "clipNotFound: no clip with id \(unknown.uuidString) — use project.snapshot to list clips")
    }

    // MARK: - sing.proposeHarmony (§4.7)

    @Test("sing.proposeHarmony with a given key: a diatonic third above every lead note, read-only")
    func proposeHarmonyGivenKey() async throws {
        let rig = try await self.rig()
        let seq = await MainActor.run { rig.store.lastEditEvent?.seq }
        let response = await call(rig, "sing.proposeHarmony", [
            "clipId": .string(rig.clipID.uuidString), "interval": .string("third"), "direction": .string("above"),
            "chordSource": .string("none"), "key": .number(0), "mode": .string("major")])
        #expect(response.ok, "\(response.error ?? "")")
        let notes = response.result?["notes"]?.arrayValue ?? []
        #expect(notes.map { Int($0["leadPitch"]?.doubleValue ?? -1) } == SingWireFixture.twoUnitPitches)
        #expect(notes.map { Int($0["pitch"]?.doubleValue ?? -1) } == [64, 65, 67, 69, 71, 69, 67, 65])
        let key = response.result?["key"]
        #expect(key?["tonic"]?.doubleValue == 0)
        #expect(key?["mode"]?.stringValue == "major")
        #expect(key?["source"]?.stringValue == "given")
        #expect(key?["name"]?.stringValue == "C major")
        #expect(response.result?["range"]?["voiceId"]?.stringValue == "builtin-1")
        #expect(response.result?["range"]?["sentence"]?.stringValue != nil)
        #expect(response.result?["warnings"]?.arrayValue == [])
        #expect(await MainActor.run { rig.store.lastEditEvent?.seq } == seq, "read-only")
    }

    @Test("sing.proposeHarmony refusals: needs a key (§14 verbatim), interval, direction, voice, clip, audio, no notes")
    func proposeHarmonyRefusals() async throws {
        // Every pitch class once, equal lengths: no key can be heard.
        let atonal = try await self.rig(onsets: (0..<12).map { Double($0) + 4 }, pitches: Array(60..<72))
        let rig = try await self.rig()
        let audio = try await audioClip(rig)
        let empty = try await emptyMIDIClip(rig)
        let unknown = UUID()
        let clip = JSONValue.string(rig.clipID.uuidString)
        let third: [String: JSONValue] = ["interval": .string("third"), "direction": .string("above")]
        let cases: [(Rig, [String: JSONValue], String)] = [
            (atonal, third.merging(["clipId": .string(atonal.clipID.uuidString)]) { a, _ in a },
             "singHarmonyNeedsKey: I couldn't tell this song's key. Pick the key, and I'll work out the harmony."),
            (rig, ["clipId": clip, "interval": .string("second"), "direction": .string("above")],
             "singHarmonyIntervalInvalid: 'second' isn't a harmony interval. Pick third, sixth, fifth or octave."),
            (rig, ["clipId": clip, "interval": .string("third"), "direction": .string("up")],
             "singHarmonyIntervalInvalid: 'up' isn't a direction for a harmony. Pick above or below."),
            (rig, third.merging(["clipId": clip, "voiceId": .string("nope")]) { a, _ in a },
             "singVoiceNotFound: There is no voice \"nope\". Call sing.listVoices to see the voices you can use."),
            (rig, third.merging(["clipId": .string(unknown.uuidString)]) { a, _ in a },
             "clipNotFound: no clip with id \(unknown.uuidString) — use project.snapshot to list clips"),
            (rig, third.merging(["clipId": .string(audio.uuidString)]) { a, _ in a },
             "singNeedsMIDIClip: " + SingPlanRefusal.audioClip.sentence),
            (rig, third.merging(["clipId": .string(empty.uuidString)]) { a, _ in a },
             "singClipHasNoNotes: " + SingPlanRefusal.noNotes.sentence),
            (rig, third.merging(["clipId": clip, "mode": .string("minor")]) { a, _ in a },
             "'mode' needs 'key' (the key's note, 0 = C … 11 = B); omit both and the key is worked out from the song"),
        ]
        for (r, params, expected) in cases {
            let response = await call(r, "sing.proposeHarmony", params)
            #expect(response.error == expected)
        }
        // The same atonal clip with a key given plans fine.
        let given = await call(atonal, "sing.proposeHarmony",
                               third.merging(["clipId": .string(atonal.clipID.uuidString), "key": .number(2)]) { a, _ in a })
        #expect(given.ok, "\(given.error ?? "")")
        #expect(given.result?["key"]?["source"]?.stringValue == "given")
    }

    // MARK: - sing.capabilities (§6.9)

    @Test("sing.capabilities with no engine wired in: the LyricLanguage list (Spanish out), the five vibratos, 3 parts, engine null")
    func capabilitiesHeadless() async throws {
        let rig = try await self.rig()
        let response = await call(rig, "sing.capabilities", [:])
        #expect(response.ok, "\(response.error ?? "")")
        let languages = response.result?["languages"]?.arrayValue ?? []
        #expect(languages.map { $0["code"]?.stringValue ?? "" } == ["en", "zh", "yue"])
        #expect(languages.map { $0["name"]?.stringValue ?? "" } == ["English", "Chinese (Mandarin)", "Chinese (Cantonese)"])
        #expect(languages.allSatisfy { $0["status"]?.stringValue == "supported" })
        #expect(languages.allSatisfy { $0["needsEngineUpdate"]?.boolValue == false })
        #expect(response.result?["engine"] == .null)
        #expect(response.result?["maxParts"]?.doubleValue == 3)
        let vibrato = response.result?["expression"]?.arrayValue?.first
        #expect(vibrato?["choices"]?.arrayValue?.compactMap(\.stringValue)
            == ["asSung", "straight", "gentle", "normal", "wide"])
        let extra = await call(rig, "sing.capabilities", ["verbose": .bool(true)])
        #expect(extra.error == "sing.capabilities: unknown parameter 'verbose' — sing.capabilities takes no parameters")
    }
}

// MARK: - Spies and helpers

/// A spy in front of the expansion's lyrics writes.
@MainActor
final class SingWireEditSpy: SingLyricsEditing {
    struct LyricsCall: Equatable { var clipId: UUID; var text: String; var language: String?; var undoLabel: String }
    struct NoteWordCall: Equatable { var clipId: UUID; var noteId: UUID; var word: String; var dryRun: Bool }
    private(set) var lyricsCalls: [LyricsCall] = []
    private(set) var noteWordCalls: [NoteWordCall] = []
    let store: ProjectStore

    init(store: ProjectStore) { self.store = store }

    @discardableResult
    func setClipLyrics(clipId: UUID, text: String, language: String?, undoLabel: String) throws -> Clip {
        lyricsCalls.append(LyricsCall(clipId: clipId, text: text, language: language, undoLabel: undoLabel))
        return try store.setClipLyrics(clipId: clipId, text: text, language: language, undoLabel: undoLabel)
    }

    @discardableResult
    func setNoteWord(clipId: UUID, noteId: UUID, word: String, dryRun: Bool) throws -> LyricNoteWordResult {
        noteWordCalls.append(NoteWordCall(clipId: clipId, noteId: noteId, word: word, dryRun: dryRun))
        return try store.setNoteWord(clipId: clipId, noteId: noteId, word: word, dryRun: dryRun)
    }
}

/// A spy in front of THE style write.
@MainActor
final class SingWireStyleSpy: SingStyleWriting {
    struct Call: Equatable { var clipId: UUID; var edit: SingStyleEdit }
    private(set) var calls: [Call] = []
    let store: ProjectStore

    init(store: ProjectStore) { self.store = store }

    @discardableResult
    func setSingStyle(clipId: UUID, edit: SingStyleEdit) throws -> SingStyleWriteResult {
        calls.append(Call(clipId: clipId, edit: edit))
        return try store.setSingStyle(clipId: clipId, edit: edit)
    }
}

/// The engine spy for "one undo step": counts `tracksDidChange` (a style write tells the engine once, inside its
/// one `performEdit`). Only the members with no protocol default.
@MainActor
final class X7AEngineSpy: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted
    private(set) var tracksDidChangeCount = 0

    func prepare() throws {}
    func shutdown() {}
    func tracksDidChange(_ tracks: [Track]) { tracksDidChangeCount += 1 }
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        throw ProjectError.engineUnavailable
    }
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) { completion(false) }
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func setInputDevice(uid: String?) throws {}
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {
        throw ProjectError.recordingFailed("x7a spy")
    }
    func stopRecording() {}
}

/// S6 pins: replies captured on the UNCHANGED tree (commit e7e4d24 + wave 8, before x7), canonicalised (sorted keys,
/// every UUID replaced by its first-appearance placeholder) by the same function the capture used.
enum X7APin {
    static func canonical(_ value: JSONValue?) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let raw = String(decoding: try encoder.encode(value ?? .null), as: UTF8.self)
        let pattern = try NSRegularExpression(
            pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
        var seen: [String: String] = [:]
        var result = ""
        var last = raw.startIndex
        for match in pattern.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            let range = Range(match.range, in: raw)!
            result += raw[last..<range.lowerBound]
            let id = raw[range].uppercased()
            if seen[id] == nil { seen[id] = "<id\(seen.count + 1)>" }
            result += seen[id]!
            last = range.upperBound
        }
        result += raw[last...]
        return result
    }

    /// `pins/A-setLyrics-dryRun.json`, captured 2026-10-07 00:10 on the unchanged tree.
    static let setLyricsDryRun =
        #"{"assignment":{"lines":2,"phrases":2,"unsungNoteIds":[],"words":[{"endBeat":5,"held":false,"noteIds":["<id1>"],"startBeat":4,"text":"one"},{"endBeat":6,"held":false,"noteIds":["<id2>"],"startBeat":5,"text":"two"},{"endBeat":7,"held":false,"noteIds":["<id3>"],"startBeat":6,"text":"three"},{"endBeat":8,"held":false,"noteIds":["<id4>"],"startBeat":7,"text":"four"},{"endBeat":37,"held":false,"noteIds":["<id5>"],"startBeat":36,"text":"five"},{"endBeat":38,"held":false,"noteIds":["<id6>"],"startBeat":37,"text":"six"},{"endBeat":39,"held":false,"noteIds":["<id7>"],"startBeat":38,"text":"seven"},{"endBeat":40,"held":false,"noteIds":["<id8>"],"startBeat":39,"text":"eight"}]},"changed":true,"clipId":"<id9>","stored":false,"text":"one two three four\nfive six seven eight","warnings":[]}"#
    /// `pins/B-setLyrics-store.json`, captured 2026-10-07 00:10 on the unchanged tree.
    static let setLyricsStore =
        #"{"assignment":{"lines":2,"phrases":2,"unsungNoteIds":[],"words":[{"endBeat":5,"held":false,"noteIds":["<id1>"],"startBeat":4,"text":"one"},{"endBeat":6,"held":false,"noteIds":["<id2>"],"startBeat":5,"text":"two"},{"endBeat":7,"held":false,"noteIds":["<id3>"],"startBeat":6,"text":"three"},{"endBeat":8,"held":false,"noteIds":["<id4>"],"startBeat":7,"text":"four"},{"endBeat":37,"held":false,"noteIds":["<id5>"],"startBeat":36,"text":"five"},{"endBeat":38,"held":false,"noteIds":["<id6>"],"startBeat":37,"text":"six"},{"endBeat":39,"held":false,"noteIds":["<id7>"],"startBeat":38,"text":"seven"},{"endBeat":40,"held":false,"noteIds":["<id8>"],"startBeat":39,"text":"eight"}]},"changed":true,"clipId":"<id9>","stored":true,"text":"one two three four\nfive six seven eight","warnings":[]}"#
    /// `pins/C-setLyrics-unchanged.json`, captured 2026-10-07 00:10 on the unchanged tree.
    static let setLyricsUnchanged =
        #"{"assignment":{"lines":2,"phrases":2,"unsungNoteIds":[],"words":[{"endBeat":5,"held":false,"noteIds":["<id1>"],"startBeat":4,"text":"one"},{"endBeat":6,"held":false,"noteIds":["<id2>"],"startBeat":5,"text":"two"},{"endBeat":7,"held":false,"noteIds":["<id3>"],"startBeat":6,"text":"three"},{"endBeat":8,"held":false,"noteIds":["<id4>"],"startBeat":7,"text":"four"},{"endBeat":37,"held":false,"noteIds":["<id5>"],"startBeat":36,"text":"five"},{"endBeat":38,"held":false,"noteIds":["<id6>"],"startBeat":37,"text":"six"},{"endBeat":39,"held":false,"noteIds":["<id7>"],"startBeat":38,"text":"seven"},{"endBeat":40,"held":false,"noteIds":["<id8>"],"startBeat":39,"text":"eight"}]},"changed":false,"clipId":"<id9>","stored":true,"text":"one two three four\nfive six seven eight","warnings":[]}"#
    /// `pins/D-getLyrics.json`, captured 2026-10-07 00:10 on the unchanged tree.
    static let getLyrics =
        #"{"assignment":{"lines":2,"phrases":2,"unsungNoteIds":[],"words":[{"endBeat":5,"held":false,"noteIds":["<id1>"],"startBeat":4,"text":"one"},{"endBeat":6,"held":false,"noteIds":["<id2>"],"startBeat":5,"text":"two"},{"endBeat":7,"held":false,"noteIds":["<id3>"],"startBeat":6,"text":"three"},{"endBeat":8,"held":false,"noteIds":["<id4>"],"startBeat":7,"text":"four"},{"endBeat":37,"held":false,"noteIds":["<id5>"],"startBeat":36,"text":"five"},{"endBeat":38,"held":false,"noteIds":["<id6>"],"startBeat":37,"text":"six"},{"endBeat":39,"held":false,"noteIds":["<id7>"],"startBeat":38,"text":"seven"},{"endBeat":40,"held":false,"noteIds":["<id8>"],"startBeat":39,"text":"eight"}]},"clipId":"<id9>","problem":null,"text":"one two three four\nfive six seven eight","warnings":[]}"#
    /// `pins/E-getLyrics-problem.json`, captured 2026-10-07 00:10 on the unchanged tree.
    static let getLyricsProblem =
        #"{"assignment":{"lines":0,"phrases":0,"unsungNoteIds":[],"words":[]},"clipId":"<id1>","problem":{"code":"lyricsTooManyWords","sentence":"This line has 8 words but the tune has 4 notes. Each note sings one word, so remove 4 words or add 4 notes."},"text":"one two three four\nfive six seven eight","warnings":[]}"#
    /// `pins/F-getLyrics-none.json`, captured 2026-10-07 00:10 on the unchanged tree.
    static let getLyricsNone =
        #"{"assignment":{"lines":0,"phrases":0,"unsungNoteIds":[],"words":[]},"clipId":"<id1>","problem":null,"text":"","warnings":[]}"#
    /// `pins/G-mixerApplyPreset.json`, captured 2026-10-07 00:10 on the unchanged tree.
    static let mixerApplyPreset =
        #"{"effects":[{"id":"<id1>","isBypassed":false,"kind":"eq","latencySamples":0,"params":{"highPassEnabled":0,"highPassFreq":20,"highPassSlopeDbPerOct":12,"highShelfEnabled":1,"highShelfFreq":10000,"highShelfGainDb":2,"highShelfQ":0.7071067811865476,"lowPassEnabled":0,"lowPassFreq":20000,"lowPassSlopeDbPerOct":12,"lowShelfEnabled":1,"lowShelfFreq":100,"lowShelfGainDb":-3,"lowShelfQ":0.7071067811865476,"peak1Enabled":1,"peak1Freq":3000,"peak1GainDb":2.5,"peak1Q":1,"peak2Enabled":1,"peak2Freq":3000,"peak2GainDb":0,"peak2Q":1}},{"id":"<id2>","isBypassed":false,"kind":"compressor","latencySamples":0,"params":{"attackMs":10,"detectorBandwidthApplies":0,"detectorBandwidthHz":3250,"detectorFreqHz":6500,"detectorMode":0,"detectorQ":2,"kneeDb":6,"latencySamples":0,"makeupDb":0,"mix":1,"ratio":3,"releaseMs":100,"resolvedDetectorMode":"off","thresholdDb":-18}}],"trackId":"<id3>"}"#
    /// `pins/H-setLyrics-missingText-error.json`, captured 2026-10-07 00:10 on the unchanged tree.
    static let setLyricsMissingText =
        #"missing or invalid required param 'text' (a string; "" clears the lyrics)"#
    /// `pins/I-setLyrics-held-dryRun.json`, captured 2026-10-07 00:10 on the unchanged tree.
    static let setLyricsHeldDryRun =
        #"{"assignment":{"lines":2,"phrases":2,"unsungNoteIds":[],"words":[{"endBeat":5,"held":false,"noteIds":["<id1>"],"startBeat":4,"text":"one"},{"endBeat":6,"held":false,"noteIds":["<id2>"],"startBeat":5,"text":"two"},{"endBeat":8,"held":true,"noteIds":["<id3>","<id4>"],"startBeat":6,"text":"three"},{"endBeat":37,"held":false,"noteIds":["<id5>"],"startBeat":36,"text":"five"},{"endBeat":38,"held":false,"noteIds":["<id6>"],"startBeat":37,"text":"six"},{"endBeat":39,"held":false,"noteIds":["<id7>"],"startBeat":38,"text":"seven"},{"endBeat":40,"held":false,"noteIds":["<id8>"],"startBeat":39,"text":"eight"}]},"changed":true,"clipId":"<id9>","stored":false,"text":"one two three\nfive six seven eight","warnings":["The tune has 1 more note than your words need. I held 'three' across it. Add words, or drag a word to cover different notes."]}"#
}
