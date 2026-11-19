import CryptoKit
import Foundation
import Testing
@testable import AIServices
@testable import DAWControl
@testable import DAWCore

/// p2-sing-e part 2: the voice verbs (design §6 rows 7–9, 11) through the router. `sing.addVoice` runs the clip
/// check, the range and Route N in Swift, with no engine: the pitch frames are scripted (VoiceClipCheckTests'
/// clean P1 take), the audio is real (a 16 kHz WAV read back through AVFoundation), and every voice is written under
/// the test's own root, never the user's library.
@Suite("SingWire — sing.addVoice / listVoices / removeVoice / proposeKey (p2-sing-e)")
struct SingWireVoiceTests {

    struct Rig {
        let router: CommandRouter
        let store: ProjectStore
        let clipID: UUID
        let services: SingWireServices
        let jobs: SingWireFakeJobs
        let root: URL
        var voices: URL { services.voices.root }
    }

    private func rig(transcribe: @escaping @Sendable (URL) async throws -> String? = { _ in nil }) async throws -> Rig {
        let root = try SingWireFixture.tempDir("voice")
        let base = URL(string: "http://127.0.0.1:\(try SingWireFixture.unusedLoopbackPort())")!
        let lifecycle = await SingWireFixture.lifecycle(root, baseURL: base)
        let engine = SingWireFakeEngine(config: SingWireFixture.config(root: root, baseURL: base, lifecycle: lifecycle),
                                        state: .installedNotRunning)
        let jobs = SingWireFakeJobs()
        let probe = SingWireInstallProbe()
        let trash = SingWireFixture.trash(into: root)
        return try await MainActor.run {
            let (store, clipID) = try SingWireFixture.store(root: root, lyrics: SingWireFixture.twoUnitLyrics)
            let services = SingWireFixture.services(root: root, engine: engine, jobs: jobs,
                                                    installFunction: probe.function, transcribe: transcribe,
                                                    trash: trash)
            return Rig(router: CommandRouter(store: store, singServices: services), store: store, clipID: clipID,
                       services: services, jobs: jobs, root: root)
        }
    }

    private func call(_ rig: Rig, _ verb: String, _ params: [String: JSONValue] = [:]) async -> ControlResponse {
        await rig.router.handle(SingWireFixture.request(verb, params))
    }

    private func takeFile(_ rig: Rig, seconds: Double = 6.8, noiseDb: Double = -70) throws -> URL {
        let url = rig.root.appendingPathComponent("take-\(UUID().uuidString).wav")
        try SingWireFixture.writeTake(url, total: seconds, noiseDb: noiseDb)
        return url
    }

    /// Voice folders (and any leftover staging folder) under the voices root.
    private func entries(_ rig: Rig) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: rig.voices.path)) ?? []).sorted()
    }

    @Test("a clean recording is saved: voice.json + reference.wav under the injected root, listed after the built-in singer, word check in the background")
    func addVoiceFromFileSaves() async throws {
        let rig = try await rig(transcribe: { _ in "Row, row, row your boat, gently down the stream" })
        let response = await call(rig, "sing.addVoice", ["path": .string(try takeFile(rig).path),
                                                         "name": .string("  Studio voice  ")])
        #expect(response.ok, "\(response.error ?? "")")
        let id = try #require(response.result?["id"]?.stringValue)
        #expect(SingVoiceLibrary.isValidID(id))
        #expect(response.result?["name"]?.stringValue == "Studio voice")
        #expect(response.result?["kind"]?.stringValue == "own")
        #expect(response.result?["source"]?.stringValue == "file")
        let record = try rig.services.voices.record(id: id)
        #expect(response.result?["message"]?.stringValue == VoiceRangeFit.voiceSavedSentence(record.range)
            + (record.labels.verdict == .poor ? " " + VoiceReferenceLabeler.poorAlignmentMessage : ""))
        #expect(response.result?["message"]?.stringValue?.hasPrefix("Your voice sits around ") == true)
        #expect(record.check.passed)
        #expect(abs(record.durationS - 6.8) < 0.01)
        #expect(record.sampleRate == 16_000)
        #expect(!record.labels.notes.isEmpty)
        let reference = rig.services.voices.referenceURL(for: id)
        #expect(record.referenceSha256
            == SHA256.hash(data: try Data(contentsOf: reference)).map { String(format: "%02x", $0) }.joined())
        #expect(entries(rig) == [id], "one folder, no staging left behind")

        let list = await call(rig, "sing.listVoices")
        let voices = list.result?["voices"]?.arrayValue ?? []
        #expect(voices.map { $0["id"]?.stringValue ?? "" } == ["builtin-1", id])
        #expect(voices.first?["name"]?.stringValue == "Built-in singer")
        #expect(voices.first?["range"]?["p50Midi"]?.doubleValue == 65.9)
        #expect(voices.first?["available"]?.boolValue == false, "no engine installed in this test")
        let savedKeys: Set<String> = Set(voices.last?.objectValue.map { Array($0.keys) } ?? [])
        #expect(savedKeys.isSuperset(of: ["id", "name", "kind", "createdAt", "durationS", "range", "alignment",
                                          "wordCheck"]))
        let rangeKeys: Set<String> = Set(voices.last?["range"]?.objectValue.map { Array($0.keys) } ?? [])
        #expect(rangeKeys == ["p10Midi", "p50Midi", "p90Midi", "lowNote", "medianNote"])

        let checked = await SingWireFixture.waitUntil(10) {
            (try? rig.services.voices.record(id: id).wordCheck) != nil
        }
        #expect(checked, "the background word check wrote its result")
        let wordCheck = try rig.services.voices.record(id: id).wordCheck
        #expect(wordCheck?.state == "checked" && wordCheck?.wer == 0 && wordCheck?.verdict == "clear")
    }

    @Test("Route N's labels become the facade's prompt notes: window-relative, the guide's words, gently continued")
    func promptNotesFromLabels() async throws {
        let rig = try await rig()
        let response = await call(rig, "sing.addVoice", ["path": .string(try takeFile(rig).path)])
        let id = try #require(response.result?["id"]?.stringValue, "\(response.error ?? "")")
        let record = try rig.services.voices.record(id: id)
        let own = rig.services.voices.ownVoice(record)
        #expect(own.name == "My voice")
        #expect(own.referencePath == rig.voices.appendingPathComponent(id).appendingPathComponent("reference.wav").path)
        #expect(own.windowStartS == record.labels.windowStartSeconds)
        #expect(own.promptNotes.count == record.labels.notes.count)
        let words = own.promptNotes.map(\.word)
        #expect(words == record.labels.notes.map { note in
            SingGuideLine.words.first { $0.noteIndices.contains(note.index) }?.text ?? "?"
        })
        for (note, prompt) in zip(record.labels.notes, own.promptNotes) {
            #expect(abs(prompt.startS - (note.startSeconds - record.labels.windowStartSeconds)) < 1e-9)
            #expect(prompt.midi == note.midi)
            #expect(prompt.continues == (note.index == 6), "only gently's second note continues a word")
        }
        #expect(own.promptNotes.first?.continues == false)
    }

    @Test("the clip check's refusals come back in §5.7's words, and a refused take leaves nothing behind")
    func addVoiceRefusals() async throws {
        let rig = try await rig()
        let short = await call(rig, "sing.addVoice", ["path": .string(try takeFile(rig, seconds: 2.0).path)])
        #expect(short.error == "singVoiceTooShort: Your recording is only 2.0 seconds long. Please record the whole "
            + "line again — it takes about 5 seconds.")
        let long = await call(rig, "sing.addVoice", ["path": .string(try takeFile(rig, seconds: 13.0).path)])
        #expect(long.error == "singVoiceTooLong: Your recording is 13.0 seconds long. Please use one under 12 "
            + "seconds that stops a moment after the singing ends.")
        let noisy = await call(rig, "sing.addVoice", ["path": .string(try takeFile(rig, noiseDb: -40).path)])
        #expect(noisy.error == "singVoiceNoisy: There's too much background sound (music, a TV or a fan) around your "
            + "singing. Please record again somewhere quieter, with nothing playing.")
        let missing = rig.root.appendingPathComponent("nothing-here.wav").path
        #expect(await call(rig, "sing.addVoice", ["path": .string(missing)]).error
            == "singVoiceFileUnreadable: I couldn't read that recording as audio (there is no file at \(missing)). "
                + "Please use a WAV, AIFF, M4A or MP3 file.")
        let garbage = rig.root.appendingPathComponent("garbage.wav")
        try Data("this is not audio".utf8).write(to: garbage)
        let unreadable = await call(rig, "sing.addVoice", ["path": .string(garbage.path)])
        #expect(unreadable.error?.hasPrefix("singVoiceFileUnreadable: I couldn't read that recording as audio (") == true,
                "\(unreadable.error ?? "ok")")
        #expect(unreadable.error?.hasSuffix("). Please use a WAV, AIFF, M4A or MP3 file.") == true)
        #expect(await call(rig, "sing.addVoice", [:]).error
            == "sing.addVoice: pass exactly one of 'path' (an audio file) or 'clipId' (an audio clip)")
        #expect(await call(rig, "sing.addVoice", ["path": .string("relative.wav")]).error
            == "'path' must be an absolute path")
        #expect(entries(rig).isEmpty, "nothing saved, no staging folder left: \(entries(rig))")
    }

    @Test("a voice from an audio clip of the song; a MIDI, stretched or unknown clip is refused in words")
    func addVoiceFromClip() async throws {
        let rig = try await rig()
        let wav = try takeFile(rig)
        let (audioTrack, audioClip) = try await MainActor.run { () -> (UUID, UUID) in
            let track = rig.store.addTrack(kind: .audio)
            return (track.id, try rig.store.importAudio(url: wav, toTrack: track.id, atBeat: 0).id)
        }
        let saved = await call(rig, "sing.addVoice", ["clipId": .string(audioClip.uuidString)])
        #expect(saved.ok, "\(saved.error ?? "")")
        #expect(saved.result?["source"]?.stringValue == "clip")

        #expect(await call(rig, "sing.addVoice", ["clipId": .string(rig.clipID.uuidString)]).error
            == "singVoiceNeedsAudioClip: A voice is made from a recording of someone singing. This clip is MIDI "
                + "notes, so pick an audio clip instead.")
        _ = try await MainActor.run { try rig.store.setClipStretch(trackId: audioTrack, clipId: audioClip, ratio: 1.25) }
        #expect(await call(rig, "sing.addVoice", ["clipId": .string(audioClip.uuidString)]).error
            == "singVoiceClipStretched: This clip is time-stretched, so it no longer sounds the way it was sung. Set "
                + "its stretch back to normal, or use the original recording.")
        let unknown = UUID()
        #expect(await call(rig, "sing.addVoice", ["clipId": .string(unknown.uuidString)]).error
            == "clipNotFound: no clip with id \(unknown.uuidString) — use project.snapshot to list clips")
    }

    @Test("removeVoice moves the folder to the (injected) Trash; the built-in singer and unknown ids are refused; a broken voice can still be removed")
    func removeVoice() async throws {
        let rig = try await rig()
        let added = await call(rig, "sing.addVoice", ["path": .string(try takeFile(rig).path)])
        let id = try #require(added.result?["id"]?.stringValue, "\(added.error ?? "")")
        let removed = await call(rig, "sing.removeVoice", ["voiceId": .string(id)])
        #expect(removed.result?["movedToTrash"]?.stringValue
            == rig.root.appendingPathComponent("Trash").appendingPathComponent(id).path)
        #expect(entries(rig).isEmpty)
        #expect(await call(rig, "sing.listVoices").result?["voices"]?.arrayValue?.count == 1)

        #expect(await call(rig, "sing.removeVoice", ["voiceId": .string("builtin-1")]).error
            == "singVoiceBuiltIn: The built-in singer comes with the singing engine, so it can't be removed.")
        for bad in ["voice-nope", "../etc", id] {
            #expect(await call(rig, "sing.removeVoice", ["voiceId": .string(bad)]).error
                == "singVoiceNotFound: There is no voice \"\(bad)\". Call sing.listVoices to see the voices you can use.")
        }

        let broken = rig.voices.appendingPathComponent("voice-broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: broken.appendingPathComponent("voice.json"))
        let list = await call(rig, "sing.listVoices")
        #expect(list.result?["unreadable"]?.arrayValue == [.string("voice-broken")], "reported, never skipped silently")
        #expect(await call(rig, "sing.removeVoice", ["voiceId": .string("voice-broken")]).ok)
    }

    @Test("proposeKey: VoiceRangeFit's proposal for the clip's melody against the built-in or a saved voice, and its refusals")
    func proposeKey() async throws {
        let rig = try await rig()
        let builtIn = await call(rig, "sing.proposeKey", ["clipId": .string(rig.clipID.uuidString)])
        #expect(builtIn.ok, "\(builtIn.error ?? "")")
        let expected = try await MainActor.run { () -> KeyProposal in
            let clip = try #require(rig.store.tracks.flatMap(\.clips).first { $0.id == rig.clipID })
            let melody = SingPlanner.melody(of: clip).notes.map {
                VoiceRangeFit.MelodyNote(midi: Double($0.pitch), durationSeconds: rig.store.transport.tempoMap.seconds(
                    from: clip.startBeat + $0.startBeat, to: clip.startBeat + $0.startBeat + $0.lengthBeats))
            }
            return try #require(VoiceRangeFit.propose(melody: melody, voice: SingVoiceLibrary.builtInRange))
        }
        #expect(builtIn.result?["recommendation"]?["kind"]?.stringValue == expected.kind.rawValue)
        #expect(builtIn.result?["recommendation"]?["octaveShift"]?.doubleValue
            == Double(expected.recommendation.octaveShift))
        #expect(builtIn.result?["recommendation"]?["calibrated"]?.boolValue == false)
        #expect(builtIn.result?["sentence"]?.stringValue == expected.sentence)
        #expect(builtIn.result?["voice"]?["id"]?.stringValue == "builtin-1")
        #expect(builtIn.result?["melody"]?["lowMidi"]?.doubleValue == 60)
        #expect(builtIn.result?["melody"]?["highMidi"]?.doubleValue == 67)

        let added = await call(rig, "sing.addVoice", ["path": .string(try takeFile(rig).path)])
        let id = try #require(added.result?["id"]?.stringValue)
        let own = await call(rig, "sing.proposeKey", ["clipId": .string(rig.clipID.uuidString), "voiceId": .string(id)])
        #expect(own.result?["voice"]?["name"]?.stringValue == "My voice", "\(own.error ?? "")")

        #expect(await call(rig, "sing.proposeKey", ["clipId": .string(rig.clipID.uuidString),
                                                    "voiceId": .string("voice-nope")]).error
            == "singVoiceNotFound: There is no voice \"voice-nope\". Call sing.listVoices to see the voices you can use.")
        let (audioClip, emptyClip) = try await MainActor.run { () -> (UUID, UUID) in
            let wav = rig.root.appendingPathComponent("a.wav")
            try SingWAV.writeFloat32Mono([Float](repeating: 0, count: 4_800), sampleRate: 48_000, to: wav)
            let audio = try rig.store.importAudio(url: wav, toTrack: rig.store.addTrack(kind: .audio).id, atBeat: 0).id
            let empty = try rig.store.addMIDIClip(toTrack: rig.store.addTrack(kind: .instrument).id, atBeat: 0,
                                                  lengthBeats: 4).id
            return (audio, empty)
        }
        #expect(await call(rig, "sing.proposeKey", ["clipId": .string(audioClip.uuidString)]).error
            == "singNeedsMIDIClip: Sing needs a melody clip with notes. This one is audio.")
        #expect(await call(rig, "sing.proposeKey", ["clipId": .string(emptyClip.uuidString)]).error
            == "singClipHasNoNotes: This clip has no notes to sing. Add the tune first, then the words.")
    }
}
