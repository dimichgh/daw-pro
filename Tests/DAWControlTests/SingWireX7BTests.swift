import Foundation
import Testing
@testable import AIServices
@testable import DAWControl
@testable import DAWCore

/// p2-sing-x7 part B (W8-X7B): `sing.render {parts, key, mode}`, `sing.jobStatus.parts`, the own voice's range reaching
/// a part's octave fit, and `ai.writeLyrics {fitClipId, language}` (design `docs/design/2026-10-06-p2-sing-expansion.md`
/// §4.7, §8.3, §8.4). Nonisolated (the tree is at its `@MainActor` suite cap): every store read hops to the main actor.
///
/// SPY: `parts` must reach X6's `SingJobRequest.parts` (a recording `SingJobSubmitting`), never a wire-side copy of
/// the planner. The job tests run the REAL coordinator with a fake engine and a fake synthesizer that writes a sine
/// at every planned note (no sidecar, no model, no network). The lyrics writer is a scripted fake: no API call, no key.
@Suite("SingWire x7b — sing.render parts, jobStatus parts, own-voice range, writeLyrics fit (p2-sing-x7b)")
struct SingWireX7BTests {

    // MARK: - Rigs

    struct SpyRig {
        let router: CommandRouter
        let store: ProjectStore
        let clipID: UUID
        let jobs: SingWireFakeJobs
        let lyricsSpy: SingWireLyricsSpy
        let root: URL
    }

    /// The wire in front of a recording coordinator (`SingWireFakeJobs`).
    private func spyRig(lyrics: String? = SingWireFixture.twoUnitLyrics,
                        onsets: [Double] = SingWireFixture.twoUnitOnsets,
                        pitches: [Int] = SingWireFixture.twoUnitPitches) async throws -> SpyRig {
        let root = try SingWireFixture.tempDir("x7b-spy")
        let base = URL(string: "http://127.0.0.1:\(try SingWireFixture.unusedLoopbackPort())")!
        let lifecycle = await SingWireFixture.lifecycle(root, baseURL: base)
        let engine = SingWireFakeEngine(config: SingWireFixture.config(root: root, baseURL: base, lifecycle: lifecycle),
                                        state: .installedNotRunning)
        let jobs = SingWireFakeJobs()
        let probe = SingWireInstallProbe()
        return try await MainActor.run {
            let (store, clipID) = try SingWireFixture.store(root: root, lyrics: lyrics, onsets: onsets, pitches: pitches)
            let spy = SingWireLyricsSpy(store: store)
            let services = SingWireFixture.services(root: root, engine: engine, jobs: jobs,
                                                    installFunction: probe.function,
                                                    trash: SingWireFixture.trash(into: root))
            return SpyRig(router: CommandRouter(store: store, singServices: services, singLyrics: spy), store: store,
                          clipID: clipID, jobs: jobs, lyricsSpy: spy, root: root)
        }
    }

    struct JobRig {
        let router: CommandRouter
        let store: ProjectStore
        let clipID: UUID
        let coordinator: SingJobCoordinator
        let services: SingWireServices
        let synth: X7BSineSynth
        let root: URL
    }

    /// The wire in front of the REAL coordinator: a fake engine that boots at once, a sine synthesizer, the sine
    /// pitch tracker (`SingWireStubPitch`), and a transcriber that hears the lead's words.
    private func jobRig(lyrics: String? = SingWireFixture.twoUnitLyrics) async throws -> JobRig {
        let root = try SingWireFixture.tempDir("x7b-job")
        let base = URL(string: "http://127.0.0.1:\(try SingWireFixture.unusedLoopbackPort())")!
        let lifecycle = await SingWireFixture.lifecycle(root, baseURL: base)
        let wireEngine = SingWireFakeEngine(
            config: SingWireFixture.config(root: root, baseURL: base, lifecycle: lifecycle), state: .installedNotRunning)
        let jobEngine = X7BFakeEngine(lifecycle: lifecycle)
        let synth = X7BSineSynth()
        let probe = SingWireInstallProbe()
        let cacheDir = root.appendingPathComponent("phrase-cache", isDirectory: true)
        let (store, clipID) = try await MainActor.run {
            try SingWireFixture.store(root: root, lyrics: lyrics)
        }
        let coordinator = SingJobCoordinator(
            store: store, engine: jobEngine, synthesizer: synth, lifecycle: lifecycle,
            cache: SingPhraseCache(directory: cacheDir),
            detectPitch: { url in try SingWireStubPitch.frames(at: url) },
            transcribe: { _ in "one two three four five six seven eight" },
            configuration: SingJobCoordinator.Configuration(
                outputSampleRate: 24_000, modelPollSeconds: 0.002, enginePollSeconds: 0.002,
                sleepSeconds: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) },
                songGeneratorRunsOutside: { false }))
        let (router, services) = await MainActor.run { () -> (CommandRouter, SingWireServices) in
            let services = SingWireFixture.services(root: root, engine: wireEngine, jobs: coordinator,
                                                    installFunction: probe.function,
                                                    trash: SingWireFixture.trash(into: root))
            return (CommandRouter(store: store, singServices: services), services)
        }
        return JobRig(router: router, store: store, clipID: clipID, coordinator: coordinator, services: services,
                      synth: synth, root: root)
    }

    /// How long a job may take on a loaded machine (X6 measured a three-part job at 21 s in a 57-test parallel run).
    static let patience: Double = 120

    private func call(_ router: CommandRouter, _ verb: String, _ params: [String: JSONValue]) async -> ControlResponse {
        await router.handle(SingWireFixture.request(verb, params))
    }

    /// Polls `sing.jobStatus` until the job is done, failed or cancelled; returns the last reply.
    private func finish(_ router: CommandRouter, _ jobID: String) async throws -> [String: JSONValue] {
        var last: ControlResponse?
        let ended = await SingWireFixture.waitUntil(Self.patience) {
            last = await self.call(router, "sing.jobStatus", ["jobId": .string(jobID)])
            let state = last?.result?["state"]?.stringValue
            return state == "done" || state == "failed" || state == "cancelled"
        }
        let status = try #require(last?.result?.objectValue, "\(last?.error ?? "no reply")")
        #expect(ended, "the job reads \(status["phase"]?.stringValue ?? "?"): \(status["stageText"]?.stringValue ?? "")")
        return status
    }

    private static let third: JSONValue = .object(["kind": .string("harmony"), "interval": .string("third"),
                                                    "direction": .string("above")])

    // MARK: - SPY: parts reach X6's SingJobRequest.parts

    @Test("SPY: sing.render {parts, key, mode} hands the coordinator X6's SingJobParts and SongKey, not a wire copy")
    func partsReachTheCoordinatorRequest() async throws {
        let rig = try await spyRig()
        let other = try await MainActor.run { () -> UUID in
            let track = rig.store.addTrack(kind: .instrument)
            return try rig.store.addMIDIClip(toTrack: track.id, name: "Other", atBeat: 0, lengthBeats: 8,
                                             notes: [MIDINote(pitch: 55, startBeat: 4, lengthBeats: 1)]).id
        }
        let response = await call(rig.router, "sing.render", [
            "clipId": .string(rig.clipID.uuidString), "key": .number(7), "mode": .string("minor"),
            "parts": .array([
                Self.third,
                .object(["kind": .string("double"), "seed": .number(99), "pan": .number(0.2),
                         "volumeDb": .number(-3), "trackName": .string(" Dbl ")]),
                .object(["kind": .string("clip"), "sourceClipId": .string(other.uuidString)]),
            ])])
        #expect(response.ok, "\(response.error ?? "")")
        let request = try #require(await rig.jobs.submitted.first)
        #expect(request.parts == [
            SingJobPart(.harmony(HarmonySpec(interval: .third, direction: .above, chordSource: .auto))),
            SingJobPart(.double, seed: 99, trackName: "Dbl", pan: 0.2, volumeDb: -3),
            SingJobPart(.clip(other)),
        ])
        #expect(request.key == SongKey(tonicPitchClass: 7, mode: .minor, source: .given))
        #expect(request.fromAgent)
        // `parts` was sent, so the plan carries the coordinator's plan of the lines (this spy plans none).
        #expect(response.result?["plan"]?["parts"]?.arrayValue == [])

        let chord = await call(rig.router, "sing.render", [
            "clipId": .string(rig.clipID.uuidString),
            "parts": .array([.object(["kind": .string("chordTones"), "interval": .string("sixth"),
                                      "chordSource": .string("thisClip")])])])
        #expect(chord.ok, "\(chord.error ?? "")")
        let second = try #require(await rig.jobs.submitted.last)
        #expect(second.parts == [SingJobPart(.chordTones(rank: .second, fillInterval: .sixth,
                                                         fillChordSource: .thisClip))])
        #expect(second.key == nil, "no key given: the coordinator estimates it")
    }

    @Test("parts: [] is the base verb: no parts, no key, no plan.parts")
    func emptyPartsIsTheBaseVerb() async throws {
        let rig = try await spyRig()
        let response = await call(rig.router, "sing.render", ["clipId": .string(rig.clipID.uuidString),
                                                              "parts": .array([])])
        #expect(response.ok, "\(response.error ?? "")")
        let request = try #require(await rig.jobs.submitted.first)
        #expect(request.parts.isEmpty && request.key == nil)
        #expect(response.result?["plan"]?["parts"] == nil)
        #expect(response.result?["status"]?["parts"] == nil)
    }

    // MARK: - Refusals, each sentence exactly

    @Test("every parts refusal reads \"<code>: <sentence>\" exactly; none stores the new lyrics or submits")
    func partsRefusalsExact() async throws {
        let rig = try await spyRig()
        let clip = JSONValue.string(rig.clipID.uuidString)
        let missing = UUID()
        let lyrics = JSONValue.string("one two three four\nfive six seven nine")
        let cases: [([String: JSONValue], String)] = [
            (["parts": .array([Self.third, Self.third, Self.third, Self.third])],
             "singTooManyParts: You can add up to 3 harmony parts."),
            (["parts": .string("third above")],
             #"singPartInvalid: 'parts' must be a list of parts, like [{"kind": "harmony", "interval": "third", "direction": "above"}]."#),
            (["parts": .array([.string("double")])],
             #"singPartInvalid: Part 1 must be an object, like {"kind": "double"}."#),
            (["parts": .array([.object(["interval": .string("third")])])],
             "singPartInvalid: Part 1 needs a kind: harmony, chordTones, clip or double."),
            (["parts": .array([.object(["kind": .string("triple")])])],
             "singPartInvalid: Part 1 needs a kind: harmony, chordTones, clip or double."),
            (["parts": .array([Self.third, .object(["kind": .string("double"), "interval": .string("third")])])],
             "singPartInvalid: Part 2 (double) doesn't take 'interval'. It takes: kind, voiceId, seed, trackName, pan, volumeDb."),
            (["parts": .array([.object(["kind": .string("harmony"), "direction": .string("above")])])],
             "singPartInvalid: Part 1 (harmony) needs an interval: third, sixth, fifth or octave."),
            (["parts": .array([.object(["kind": .string("harmony"), "interval": .string("third")])])],
             "singPartInvalid: Part 1 (harmony) needs a direction: above or below."),
            (["parts": .array([.object(["kind": .string("harmony"), "interval": .string("ninth"),
                                        "direction": .string("above")])])],
             "singHarmonyIntervalInvalid: 'ninth' isn't a harmony interval. Pick third, sixth, fifth or octave."),
            (["parts": .array([.object(["kind": .string("harmony"), "interval": .string("third"),
                                        "direction": .string("up")])])],
             "singHarmonyIntervalInvalid: 'up' isn't a direction for a harmony. Pick above or below."),
            (["parts": .array([.object(["kind": .string("clip")])])],
             "singPartInvalid: Part 1 (clip) needs sourceClipId: the id of another MIDI melody clip, from project.snapshot."),
            (["parts": .array([.object(["kind": .string("clip"), "sourceClipId": .string(missing.uuidString)])])],
             "singPartClipNotFound: No clip with id \(missing.uuidString) — pick another melody clip that is in the song."),
            (["parts": .array([.object(["kind": .string("double"), "seed": .number(-1)])])],
             "singPartInvalid: Part 1 has a seed that isn't a whole number from 0 to 9007199254740991."),
            (["parts": .array([.object(["kind": .string("double"), "trackName": .string("  ")])])],
             "singPartInvalid: Part 1 has a trackName that is empty. Give it a name, or leave it out."),
            (["parts": .array([.object(["kind": .string("double"), "pan": .string("left")])])],
             "singPartInvalid: Part 1 has a pan that isn't a number from −1 to 1."),
            (["parts": .array([.object(["kind": .string("double"), "volumeDb": .bool(true)])])],
             "singPartInvalid: Part 1 has a volumeDb that isn't a number of dB from −60 to +6."),
            (["parts": .array([.object(["kind": .string("double"), "voiceId": .string("")])])],
             "singPartInvalid: Part 1 has a voiceId that isn't a voice id. Call sing.listVoices to see them."),
            (["parts": .array([.object(["kind": .string("double"), "voiceId": .string("voice-nope")])])],
             "singVoiceNotFound: There is no voice \"voice-nope\". Call sing.listVoices to see the voices you can use."),
            (["key": .number(2)],
             "'key' and 'mode' set the key a harmony part is worked out in, so they go with 'parts'. To change the song's key, use project.transpose."),
            (["parts": .array([Self.third]), "mode": .string("minor")],
             "'mode' needs 'key' (the key's note, 0 = C … 11 = B); omit both and the key is worked out from the song"),
            (["parts": .array([Self.third]), "key": .number(12)],
             "'key' must be a whole number from 0 (C) to 11 (B)"),
        ]
        for (extra, expected) in cases {
            var params: [String: JSONValue] = ["clipId": clip, "lyrics": lyrics]
            params.merge(extra) { _, new in new }
            let response = await call(rig.router, "sing.render", params)
            #expect(response.error == expected, "\(extra.keys.sorted())")
        }
        #expect(await MainActor.run { rig.lyricsSpy.calls.isEmpty }, "no refusal stored the new lyrics")
        #expect(await rig.jobs.submitted.isEmpty, "no refusal submitted a job")
    }

    @Test("a harmony part with no key on a song whose key can't be heard is refused BEFORE the lyrics are stored (§14 verbatim)")
    func harmonyNeedsKeyBeforeStoring() async throws {
        // Every pitch class once, equal lengths: no key can be heard (X7A's proposeHarmony fixture).
        let rig = try await spyRig(lyrics: nil, onsets: (0..<12).map { Double($0) + 4 }, pitches: Array(60..<72))
        let words = JSONValue.string(Array(repeating: "la", count: 12).joined(separator: " "))
        let response = await call(rig.router, "sing.render", ["clipId": .string(rig.clipID.uuidString),
                                                              "lyrics": words, "parts": .array([Self.third])])
        #expect(response.error
            == "singHarmonyNeedsKey: I couldn't tell this song's key. Pick the key, and I'll work out the harmony.")
        #expect(await MainActor.run { rig.lyricsSpy.calls.isEmpty })
        #expect(await rig.jobs.submitted.isEmpty)
        // X7D: with parts and new words the wire plans over them first, through the coordinator; script its answer.
        let preview = try await MainActor.run { () -> SingJobCoordinator.PlanPreview in
            let plan = try rig.store.planSungVocal(clipId: rig.clipID, octaveShift: 0,
                                                   lyrics: .some(ClipLyrics(text: words.stringValue ?? ""))).plan
            return SingJobCoordinator.PlanPreview(plan: plan, parts: [], warnings: [])
        }
        await rig.jobs.setPreview(preview)
        let keyed = await call(rig.router, "sing.render", ["clipId": .string(rig.clipID.uuidString),
                                                           "lyrics": words, "parts": .array([Self.third]),
                                                           "key": .number(0)])
        #expect(keyed.ok, "a given key makes the same request singable: \(keyed.error ?? "")")
    }

    @Test("the coordinator's own part refusals reach the wire in its code and words (pan, level, a double's seed, the melody as its own part, a part's plan)")
    func coordinatorPartRefusalsReachTheWire() async throws {
        let rig = try await jobRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let clip = JSONValue.string(rig.clipID.uuidString)
        let other = try await MainActor.run { () -> UUID in
            let track = rig.store.addTrack(kind: .instrument)
            let made = try rig.store.addMIDIClip(
                toTrack: track.id, name: "Other", atBeat: 0, lengthBeats: 8,
                notes: [MIDINote(pitch: 55, startBeat: 4, lengthBeats: 1), MIDINote(pitch: 57, startBeat: 5, lengthBeats: 1)])
            for t in rig.store.tracks.indices {
                if let c = rig.store.tracks[t].clips.firstIndex(where: { $0.id == made.id }) {
                    rig.store.tracks[t].clips[c].lyrics = ClipLyrics(text: "far too many words")
                }
            }
            return made.id
        }
        let cases: [(JSONValue, String)] = [
            (.object(["kind": .string("double"), "pan": .number(1.5)]),
             "singPartInvalid: A part's pan must be between −1 (left) and 1 (right)."),
            (.object(["kind": .string("double"), "volumeDb": .number(9)]),
             "singPartInvalid: A part's level must be between −60 and +6 dB."),
            (.object(["kind": .string("double"), "seed": .number(Double(SingJobRequestBuilder.firstTakeSeed))]),
             "singPartInvalid: A double needs a different seed from the lead's; on the same seed it sings an exact copy."),
            (.object(["kind": .string("clip"), "sourceClipId": clip]),
             "singPartInvalid: That clip is the melody itself. Pick another melody clip, or double the vocal instead."),
        ]
        for (part, expected) in cases {
            let response = await call(rig.router, "sing.render", ["clipId": clip, "octaveShift": .number(0),
                                                                  "parts": .array([part])])
            #expect(response.error == expected)
        }
        let planned = await call(rig.router, "sing.render", [
            "clipId": clip, "octaveShift": .number(0),
            "parts": .array([.object(["kind": .string("clip"), "sourceClipId": .string(other.uuidString)])])])
        #expect(planned.error?.hasPrefix("lyricsTooManyWords: The part 'Other': ") == true, "\(planned.error ?? "")")
        #expect(await rig.coordinator.statuses(limit: 20).isEmpty, "a refused request queues nothing")
    }

    // MARK: - A parts job through the wire

    @Test("JOB: a harmony and a double through the wire — plan.parts, jobStatus.parts, every line landed, ONE undo removes them all")
    func twoPartJobThroughTheWire() async throws {
        let rig = try await jobRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let tracksBefore = await MainActor.run { rig.store.tracks }
        let submitted = await call(rig.router, "sing.render", [
            "clipId": .string(rig.clipID.uuidString), "octaveShift": .number(0), "key": .number(0),
            "parts": .array([Self.third, .object(["kind": .string("double")])])])
        #expect(submitted.ok, "\(submitted.error ?? "")")
        let jobID = try #require(submitted.result?["jobId"]?.stringValue)
        let planParts = try #require(submitted.result?["plan"]?["parts"]?.arrayValue)
        try #require(planParts.count == 3, "the lead and both parts are planned")
        #expect(planParts.map { $0["role"]?.stringValue } == ["lead", "harmony", "double"])
        #expect(planParts.map { $0["units"]?.doubleValue } == [2, 2, 2])
        #expect(planParts.map { $0["name"]?.stringValue } == ["lead", "third above", "double"])
        #expect(planParts[1]["range"]?["fits"]?.boolValue != nil)
        #expect(planParts[1]["trackName"]?.stringValue == "Harmony — third above · Built-in singer")
        #expect(submitted.result?["status"]?["parts"]?.arrayValue?.count == 3)

        let status = try await finish(rig.router, jobID)
        #expect(status["state"]?.stringValue == "done",
                "\(status["error"]?["message"]?.stringValue ?? "") \(status["error"]?["detail"]?.stringValue ?? "")")
        let parts = try #require(status["parts"]?.arrayValue)
        try #require(parts.count == 3)
        #expect(parts.map { $0["role"]?.stringValue } == ["lead", "harmony", "double"])
        #expect(parts.map { $0["state"]?.stringValue } == ["landed", "landed", "landed"])
        let trackIDs = parts.compactMap { $0["trackId"]?.stringValue.flatMap(UUID.init(uuidString:)) }
        #expect(trackIDs.count == 3)
        #expect(await MainActor.run { trackIDs.allSatisfy { id in rig.store.tracks.contains { $0.id == id } } })
        #expect(status["result"]?["trackId"]?.stringValue == parts[0]["trackId"]?.stringValue,
                "the lead landed, so result is the lead's take")
        #expect(await rig.synth.requests.count == 6, "two lines each for the lead, the harmony and the double")

        #expect(try await MainActor.run { try rig.store.undo() } == "Land Sung Harmony")
        #expect(await MainActor.run { rig.store.tracks } == tracksBefore, "ONE undo removes every landed line")
    }

    // MARK: - The own voice's range reaches a part's octave fit

    @Test("an own voice's measured range moves its harmony part by whole octaves (it used to sit at the lead's octave)")
    func ownVoiceRangeMovesThePart() async throws {
        let rig = try await jobRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let take = rig.root.appendingPathComponent("take.wav")
        try SingWireFixture.writeTake(take)
        let added = await call(rig.router, "sing.addVoice", ["path": .string(take.path)])
        let voiceID = try #require(added.result?["id"]?.stringValue, "\(added.error ?? "")")
        // The add's background word check rewrites voice.json when it ends: wait for it, or it would write the old
        // range back over the one set below.
        let checked = await SingWireFixture.waitUntil(30) {
            (try? rig.services.voices.record(id: voiceID).wordCheck) != nil
        }
        #expect(checked, "the background word check finished")
        // A low voice: an octave and more under the melody (C4-G4) and the built-in singer.
        let low = VoiceRange(p10Midi: 43, medianMidi: 47, p90Midi: 52)
        var record = try rig.services.voices.record(id: voiceID)
        record.range = low
        try rig.services.voices.update(record)

        // What the coordinator's own fit gives a third above with this range, and without one (the lead's octave).
        let (withRange, withoutRange) = try await MainActor.run { () -> (Int, Int) in
            let (track, clip) = try #require(SingWireHandlers.find(rig.clipID, in: rig.store.tracks))
            let key = SongKey(tonicPitchClass: 0, mode: .major)
            let plan = HarmonyPlanner.derivedPart(clip: clip, on: track, tracks: rig.store.tracks,
                                                  spec: HarmonySpec(interval: .third, direction: .above),
                                                  key: key, partIndex: 1)
            let tempo = rig.store.transport.tempoMap
            return (HarmonyPlanner.range(of: plan, clipStartBeat: clip.startBeat, tempoMap: tempo, voice: low,
                                         leadOctaveShift: 0).octaveShift,
                    HarmonyPlanner.range(of: plan, clipStartBeat: clip.startBeat, tempoMap: tempo, voice: nil,
                                         leadOctaveShift: 0).octaveShift)
        }
        #expect(withoutRange == 0)
        #expect(withRange < 0, "the low range must move the part, or this test cannot fail")

        let submitted = await call(rig.router, "sing.render", [
            "clipId": .string(rig.clipID.uuidString), "voiceId": .string(voiceID), "octaveShift": .number(0),
            "key": .number(0), "parts": .array([Self.third])])
        #expect(submitted.ok, "\(submitted.error ?? "")")
        let planParts = try #require(submitted.result?["plan"]?["parts"]?.arrayValue)
        try #require(planParts.count == 2, "the lead and the harmony are planned")
        #expect(planParts.first?["octaveShift"]?.doubleValue == 0, "the lead stays where it was asked")
        #expect(planParts.last?["octaveShift"]?.doubleValue == Double(withRange),
                "the own voice's range reached the part's fit")
        #expect(planParts.last?["voiceId"]?.stringValue == voiceID)
        let jobID = try #require(submitted.result?["jobId"]?.stringValue)
        _ = await call(rig.router, "sing.cancelJob", ["jobId": .string(jobID)])
        _ = try await finish(rig.router, jobID)
    }

    // MARK: - ai.writeLyrics {fitClipId, language}

    private func lyricsRouter(_ writer: X7BScriptedWriter) async throws -> (CommandRouter, ProjectStore, UUID) {
        let root = try SingWireFixture.tempDir("x7b-fit")
        return try await MainActor.run {
            let (store, clipID) = try SingWireFixture.store(root: root)
            return (CommandRouter(store: store, lyricsWriter: { writer }), store, clipID)
        }
    }

    @Test("FIT: tags stripped, one line per phrase, checked — a reply that fits returns after ONE ask, stores nothing")
    func fitFirstTry() async throws {
        let writer = X7BScriptedWriter(["[verse]\none two three four\n\n[chorus]\nfive six one two"])
        let (router, store, clipID) = try await lyricsRouter(writer)
        let seq = await MainActor.run { store.lastEditEvent?.seq }
        let response = await call(router, "ai.writeLyrics", ["prompt": .string("home"),
                                                             "fitClipId": .string(clipID.uuidString)])
        #expect(response.ok, "\(response.error ?? "")")
        #expect(response.result?["lyrics"]?.stringValue == "one two three four\nfive six one two")
        #expect(response.result?["provider"]?.stringValue == "anthropic")
        let fit = try #require(response.result?["fit"])
        #expect(fit["allFit"]?.boolValue == true)
        #expect(fit["attempts"]?.doubleValue == 1)
        #expect(fit["sentence"] == .null)
        #expect(fit["lines"]?.arrayValue?.map { [$0["phrase"]?.doubleValue, $0["notes"]?.doubleValue,
                                                  $0["syllables"]?.doubleValue] } == [[1, 4, 4], [2, 4, 4]])
        let requests = await writer.requests
        #expect(requests.count == 1)
        let first = try #require(requests.first)
        #expect(first.fit == LyricsFitBrief(phrases: [.init(notes: 4, seconds: 2), .init(notes: 4, seconds: 2)]))
        let user = LyricsPromptBuilder.userPrompt(first)
        #expect(user.contains("Phrase 1: 4 notes, 2.0 seconds\nPhrase 2: 4 notes, 2.0 seconds"))
        #expect(!LyricsPromptBuilder.systemPrompt(first).contains("ACE-Step"), "no bracketed-structure teaching")
        #expect(await MainActor.run { store.lastEditEvent?.seq } == seq, "nothing stored")
        #expect(await MainActor.run { store.tracks.flatMap(\.clips).first { $0.id == clipID }?.lyrics } == nil)
    }

    @Test("FIT: a writer that overshoots a line ONCE is asked again with that line named; the second reply fits")
    func fitRetryNamesTheLine() async throws {
        let writer = X7BScriptedWriter(["beautiful morning sunshine\nfive six one two",
                                        "one two three four\nfive six one two"])
        let (router, _, clipID) = try await lyricsRouter(writer)
        let response = await call(router, "ai.writeLyrics", ["prompt": .string("home"),
                                                             "fitClipId": .string(clipID.uuidString)])
        #expect(response.ok, "\(response.error ?? "")")
        let requests = await writer.requests
        try #require(requests.count == 2, "exactly one retry")
        let problems = try #require(requests.last?.fit?.problems)
        let overshoot = EnglishSyllables.estimate("beautiful") + EnglishSyllables.estimate("morning")
            + EnglishSyllables.estimate("sunshine")
        #expect(overshoot > 4, "the fixture really overshoots")
        #expect(problems == ["Line 1 has \(overshoot) syllables, but phrase 1 has only 4 notes."])
        #expect(LyricsPromptBuilder.userPrompt(requests[1]).contains(
            "Your last lines didn't fit the tune:\n- Line 1 has \(overshoot) syllables, but phrase 1 has only 4 notes."))
        #expect(response.result?["lyrics"]?.stringValue == "one two three four\nfive six one two")
        #expect(response.result?["fit"]?["allFit"]?.boolValue == true)
        #expect(response.result?["fit"]?["attempts"]?.doubleValue == 2)
    }

    @Test("FIT: a writer that overshoots TWICE is not trusted: allFit false, the bad line reported, §14's sentence names it")
    func fitTwiceOvershootReported() async throws {
        let bad = "beautiful morning sunshine\nfive six one two"
        let writer = X7BScriptedWriter([bad, bad])
        let (router, _, clipID) = try await lyricsRouter(writer)
        let response = await call(router, "ai.writeLyrics", ["prompt": .string("home"),
                                                             "fitClipId": .string(clipID.uuidString)])
        #expect(response.ok, "\(response.error ?? "")")
        #expect(await writer.requests.count == 2, "one retry, then the reply comes back with its report")
        let fit = try #require(response.result?["fit"])
        #expect(fit["allFit"]?.boolValue == false)
        #expect(fit["lines"]?.arrayValue?.map { $0["fits"]?.boolValue } == [false, true])
        #expect(fit["lines"]?.arrayValue?.first?["syllables"]?.doubleValue ?? 0 > 4)
        #expect(fit["sentence"]?.stringValue == "Some lines didn't fit the tune: 1. Edit them, or try again.")
        #expect(response.result?["lyrics"]?.stringValue == bad)
    }

    @Test("FIT: a reply with the wrong number of lines never fits (the assigner must take it line for line)")
    func fitWrongLineCount() async throws {
        let writer = X7BScriptedWriter(["one two\nthree four\nfive six", "one two three four five six one two"])
        let (router, _, clipID) = try await lyricsRouter(writer)
        let response = await call(router, "ai.writeLyrics", ["prompt": .string("home"),
                                                             "fitClipId": .string(clipID.uuidString)])
        #expect(response.ok, "\(response.error ?? "")")
        let first = try #require(await writer.requests.last?.fit?.problems.first)
        #expect(first == "You wrote 3 lines, but the tune has 2 phrases. Write exactly 2 lines, one for each phrase.")
        let fit = try #require(response.result?["fit"])
        #expect(fit["allFit"]?.boolValue == false, "one line over two phrases flows; it is not line for line")
        #expect(fit["lines"]?.arrayValue?.allSatisfy { $0["fits"]?.boolValue == false } == true)
    }

    @Test("FIT refusals: unknown, audio and empty clips, structure with fitClipId, an unsupported language; no key keeps the existing message")
    func fitRefusals() async throws {
        let writer = X7BScriptedWriter(["one two three four\nfive six one two"])
        let (router, store, clipID) = try await lyricsRouter(writer)
        let (audio, empty) = try await MainActor.run { () -> (UUID, UUID) in
            let track = store.addTrack(kind: .audio)
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent("x7b-\(UUID()).wav")
            try SingWAV.writeFloat32Mono([Float](repeating: 0, count: 4_800), sampleRate: 48_000, to: wav)
            let audio = try store.importAudio(url: wav, toTrack: track.id, atBeat: 0).id
            let midi = store.addTrack(kind: .instrument)
            return (audio, try store.addMIDIClip(toTrack: midi.id, name: "Empty", atBeat: 0, lengthBeats: 4, notes: []).id)
        }
        let unknown = UUID()
        let cases: [([String: JSONValue], String)] = [
            (["fitClipId": .string(unknown.uuidString)],
             "clipNotFound: \(ProjectError.clipNotFound(unknown).errorDescription ?? "")"),
            (["fitClipId": .string("not-a-uuid")],
             "'fitClipId' must be the id of a MIDI melody clip (a UUID string), from project.snapshot"),
            (["fitClipId": .string(audio.uuidString)], "lyricsNeedMIDIClip: \(LyricEditRefusal.needsMIDIClip.sentence)"),
            (["fitClipId": .string(empty.uuidString)], "singClipHasNoNotes: \(SingPlanRefusal.noNotes.sentence)"),
            (["fitClipId": .string(clipID.uuidString), "structure": .array([.string("verse")])],
             "'structure' asks for section tags, and words written to fit a tune have none (one line per phrase of the melody). Leave 'structure' out with 'fitClipId'."),
            (["fitClipId": .string(clipID.uuidString), "language": .string("fr")],
             "lyricsLanguageUnsupported: \(LyricRefusal.languageUnsupported(language: "fr").sentence)"),
        ]
        for (extra, expected) in cases {
            var params: [String: JSONValue] = ["prompt": .string("home")]
            params.merge(extra) { _, new in new }
            #expect(await call(router, "ai.writeLyrics", params).error == expected, "\(extra.keys.sorted())")
        }
        #expect(await writer.requests.isEmpty, "a refused request never reaches the writer")

        let keyless = await MainActor.run { () -> CommandRouter in
            CommandRouter(store: store, lyricsWriter: { throw AIServiceError.noProviderConfigured(capability: "lyrics") })
        }
        let plain = await call(keyless, "ai.writeLyrics", ["prompt": .string("home")])
        let fitted = await call(keyless, "ai.writeLyrics", ["prompt": .string("home"),
                                                            "fitClipId": .string(clipID.uuidString)])
        #expect(plain.error != nil && fitted.error == plain.error, "no key: the existing actionable message")
    }

    @Test("language: asked for in the prompt (with or without fitClipId); \"en\" is English (no line); the clip's own by default")
    func languageReachesThePrompt() async throws {
        let writer = X7BScriptedWriter(["[verse]\nlights", "一二三四\n五六七八", "one two three four\nfive six one two"])
        let (router, store, clipID) = try await lyricsRouter(writer)
        _ = await call(router, "ai.writeLyrics", ["prompt": .string("home"), "language": .string("zh")])
        let stored = await MainActor.run { () -> String? in
            for t in store.tracks.indices {
                if let c = store.tracks[t].clips.firstIndex(where: { $0.id == clipID }) {
                    store.tracks[t].clips[c].lyrics = ClipLyrics(text: "一二三四\n五六七八", language: "zh")
                }
            }
            return store.tracks.flatMap(\.clips).first { $0.id == clipID }?.lyrics?.language
        }
        #expect(stored == "zh")
        let chinese = await call(router, "ai.writeLyrics", ["prompt": .string("home"),
                                                            "fitClipId": .string(clipID.uuidString)])
        #expect(chinese.result?["fit"]?["allFit"]?.boolValue == true, "\(chinese.error ?? "")")
        let english = await call(router, "ai.writeLyrics", ["prompt": .string("home"), "language": .string("en"),
                                                            "fitClipId": .string(clipID.uuidString)])
        #expect(english.result?["fit"]?["allFit"]?.boolValue == true, "\(english.error ?? "")")
        let requests = await writer.requests
        try #require(requests.count == 3)
        #expect(requests[0].language == "zh" && requests[0].fit == nil)
        #expect(LyricsPromptBuilder.systemPrompt(requests[0]).contains("LANGUAGE: write the lyrics in Chinese (Mandarin)."))
        #expect(requests[1].language == "zh", "with fitClipId, the clip's own words' language")
        #expect(requests[2].language == nil, "\"en\" is English")
        #expect(!LyricsPromptBuilder.systemPrompt(requests[2]).contains("LANGUAGE:"))
    }
}

// MARK: - Fakes

/// A lyrics writer that answers its script in order (the last reply repeats), recording every request.
actor X7BScriptedWriter: LyricsGenerating {
    private var replies: [String]
    private(set) var requests: [LyricsWriteRequest] = []

    init(_ replies: [String]) { self.replies = replies }

    func generateLyrics(theme: String, style: String?) async throws -> String { "legacy" }

    func writeLyrics(_ request: LyricsWriteRequest) async throws -> LyricsWriteResult {
        requests.append(request)
        let reply = replies.count > 1 ? replies.removeFirst() : (replies.first ?? "")
        return LyricsWriteResult(lyrics: reply, provider: "anthropic")
    }
}

/// The singing engine for the coordinator: boots at once through the lifecycle's admission (as the manager does).
actor X7BFakeEngine: SingJobEngine {
    let lifecycle: ModelLifecycleCoordinator
    private var state: SingingSidecarState = .installedNotRunning

    init(lifecycle: ModelLifecycleCoordinator) { self.lifecycle = lifecycle }

    func status() -> SingingSidecarStatus {
        state == .healthy
            ? SingingSidecarStatus(state: state, message: "fake engine: healthy", pid: 4_001, facadeVersion: 1,
                                   commit: "fakecommit", weightsRevision: "fakeweights", weightsBytes: 1_234)
            : SingingSidecarStatus(state: state, message: "fake engine: \(state.rawValue)")
    }

    func start() async throws -> SingingSidecarStatus {
        let plan = await lifecycle.resolveAdmission(.soulxSinger)
        if let ticket = try await lifecycle.commitAdmission(plan, for: .soulxSinger) {
            await lifecycle.admitted(ticket, healthy: true)
        }
        state = .healthy
        return status()
    }

    func lastStopClassification() -> SingingStopReason? { nil }
}

/// A facade that writes a sine at every planned note (SE1's `SingFixture.render(.sine)`, copied: DAWControlTests
/// cannot import AIServicesTests), so the landing gates and the note check read real audio.
actor X7BSineSynth: SingingSynthesizing {
    private(set) var requests: [SingingPhraseRequest] = []

    func renderPhrase(_ request: SingingPhraseRequest) async throws -> SingingRenderResult {
        requests.append(request)
        let rate = Double(request.outputSampleRate)
        let lastEnd = request.notes.map(\.endS).max() ?? 0
        let seconds = ((request.leadS + lastEnd + request.trailS) * 100).rounded() / 100
        let count = Int((seconds * rate).rounded())
        var y = [Float](repeating: 0, count: count)
        for note in request.notes {
            let a = Int(((request.leadS + note.startS) * rate).rounded())
            let b = min(count, Int(((request.leadS + note.endS) * rate).rounded()))
            guard b > a else { continue }
            let w = 2 * Double.pi * 440 * pow(2, (Double(note.midi) - 69) / 12) / rate
            let fade = max(1, min(Int(0.01 * rate), (b - a) / 2))
            for k in 0..<(b - a) {
                var g = 1.0
                if k < fade {
                    g = 0.5 - 0.5 * cos(Double.pi * Double(k) / Double(fade))
                } else if k >= (b - a) - fade {
                    g = 0.5 - 0.5 * cos(Double.pi * Double((b - a) - 1 - k) / Double(fade))
                }
                y[a + k] = 0.1 * Float(g * sin(w * Double(k)))
            }
        }
        try SingWAV.writeFloat32Mono(y, sampleRate: request.outputSampleRate, to: URL(fileURLWithPath: request.outputPath))
        let peak = y.reduce(Float(0)) { max($0, abs($1)) }
        let json: [String: Any] = [
            "outputPath": request.outputPath, "sampleRate": request.outputSampleRate, "channels": 1,
            "frames": y.count, "durationS": Double(y.count) / rate, "peak": Double(peak), "rms": 0.07,
            "nonFinite": false, "seed": request.seed, "nSteps": request.nSteps, "cfg": request.cfg,
        ]
        guard let result = SingingRenderResult(json: json) else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
}
