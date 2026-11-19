import Foundation
import Testing
@testable import AIServices
@testable import DAWControl
@testable import DAWCore

/// p2-sing-x7 follow-up (W8-X7C): the own voice's range lives in ONE home (`SingVoiceLibrary.ownVoice`), a dry run
/// previews `parts` through the coordinator's own `plan(_:)`, and a refused parts request changes nothing.
/// Nonisolated (the tree is at its `@MainActor` suite cap): every store read hops to the main actor.
@Suite("SingWire x7c — one-home own-voice range, dry-run parts preview, refusals change nothing (p2-sing-x7c)")
struct SingWireX7CTests {

    // MARK: - Rigs

    struct SpyRig {
        let router: CommandRouter
        let store: ProjectStore
        let clipID: UUID
        let jobs: SingWireFakeJobs
        let voices: SingVoiceLibrary
        let root: URL
    }

    private func spyRig() async throws -> SpyRig {
        let root = try SingWireFixture.tempDir("x7c-spy")
        let base = URL(string: "http://127.0.0.1:\(try SingWireFixture.unusedLoopbackPort())")!
        let lifecycle = await SingWireFixture.lifecycle(root, baseURL: base)
        let engine = SingWireFakeEngine(config: SingWireFixture.config(root: root, baseURL: base, lifecycle: lifecycle),
                                        state: .installedNotRunning)
        let jobs = SingWireFakeJobs()
        let probe = SingWireInstallProbe()
        return try await MainActor.run {
            let (store, clipID) = try SingWireFixture.store(root: root, lyrics: SingWireFixture.twoUnitLyrics)
            let services = SingWireFixture.services(root: root, engine: engine, jobs: jobs,
                                                    installFunction: probe.function,
                                                    trash: SingWireFixture.trash(into: root))
            return SpyRig(router: CommandRouter(store: store, singServices: services), store: store, clipID: clipID,
                          jobs: jobs, voices: services.voices, root: root)
        }
    }

    struct JobRig {
        let router: CommandRouter
        let store: ProjectStore
        let clipID: UUID
        let coordinator: SingJobCoordinator
        let root: URL
    }

    /// The wire in front of the REAL coordinator (fake engine, sine synthesizer: no sidecar, model or network).
    private func jobRig() async throws -> JobRig {
        let root = try SingWireFixture.tempDir("x7c-job")
        let base = URL(string: "http://127.0.0.1:\(try SingWireFixture.unusedLoopbackPort())")!
        let lifecycle = await SingWireFixture.lifecycle(root, baseURL: base)
        let wireEngine = SingWireFakeEngine(
            config: SingWireFixture.config(root: root, baseURL: base, lifecycle: lifecycle), state: .installedNotRunning)
        let probe = SingWireInstallProbe()
        let (store, clipID) = try await MainActor.run {
            try SingWireFixture.store(root: root, lyrics: SingWireFixture.twoUnitLyrics)
        }
        let coordinator = SingJobCoordinator(
            store: store, engine: X7BFakeEngine(lifecycle: lifecycle), synthesizer: X7BSineSynth(),
            lifecycle: lifecycle, cache: SingPhraseCache(directory: root.appendingPathComponent("phrase-cache")),
            detectPitch: { url in try SingWireStubPitch.frames(at: url) },
            transcribe: { _ in "one two three four five six seven eight" },
            configuration: SingJobCoordinator.Configuration(
                outputSampleRate: 24_000, modelPollSeconds: 0.002, enginePollSeconds: 0.002,
                sleepSeconds: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) },
                songGeneratorRunsOutside: { false }))
        let router = await MainActor.run { () -> CommandRouter in
            let services = SingWireFixture.services(root: root, engine: wireEngine, jobs: coordinator,
                                                    installFunction: probe.function,
                                                    trash: SingWireFixture.trash(into: root))
            return CommandRouter(store: store, singServices: services)
        }
        return JobRig(router: router, store: store, clipID: clipID, coordinator: coordinator, root: root)
    }

    private func call(_ router: CommandRouter, _ verb: String, _ params: [String: JSONValue]) async -> ControlResponse {
        await router.handle(SingWireFixture.request(verb, params))
    }

    private static let third: JSONValue = .object(["kind": .string("harmony"), "interval": .string("third"),
                                                    "direction": .string("above")])
    private static let newWords = "la la la la la la la la"

    private func lyricsText(_ rig: JobRig) async -> String? {
        await MainActor.run {
            rig.store.tracks.lazy.flatMap(\.clips).first { $0.id == rig.clipID }?.lyrics?.text
        }
    }

    // MARK: - 1. The own voice's range, one home

    @Test("the wire's own-voice request carries EXACTLY what SingVoiceLibrary.ownVoice builds (the call the Sing sheet makes), range included")
    func ownVoiceIsBuiltInOneHome() async throws {
        let rig = try await spyRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let take = rig.root.appendingPathComponent("take.wav")
        try SingWireFixture.writeTake(take)
        let added = await call(rig.router, "sing.addVoice", ["path": .string(take.path)])
        let voiceID = try #require(added.result?["id"]?.stringValue, "\(added.error ?? "")")
        // The add's background word check rewrites voice.json when it ends: wait, or it writes the old range back.
        let checked = await SingWireFixture.waitUntil(30) { (try? rig.voices.record(id: voiceID).wordCheck) != nil }
        #expect(checked, "the background word check finished")
        let low = VoiceRange(p10Midi: 43, medianMidi: 47, p90Midi: 52)
        var record = try rig.voices.record(id: voiceID)
        record.range = low
        try rig.voices.update(record)
        record = try rig.voices.record(id: voiceID)

        // The sheet's `jobVoice` is `.own(library.ownVoice(record))` (SingSheetModel.swift): the same call, here.
        let sheetsVoice = SingJobVoice.own(rig.voices.ownVoice(record))
        #expect(sheetsVoice.range == low, "the home sets the range, so the sheet's own-voice parts are fitted too")

        let response = await call(rig.router, "sing.render", [
            "clipId": .string(rig.clipID.uuidString), "voiceId": .string(voiceID), "octaveShift": .number(0),
            "key": .number(0), "parts": .array([Self.third])])
        #expect(response.ok, "\(response.error ?? "")")
        let request = try #require(await rig.jobs.submitted.first)
        #expect(request.voice == sheetsVoice, "the wire and the sheet build the same SingOwnVoice")
    }

    @Test("SITE: the wire no longer patches the range on after ownVoice, and the sheet calls ownVoice (so the home is what both read)")
    func ownVoiceRangeSites() throws {
        let tests = URL(fileURLWithPath: #filePath)
        let repo = tests.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let wire = try String(contentsOf: repo.appendingPathComponent("Sources/DAWControl/SingWire.swift"),
                              encoding: .utf8)
        let sheet = try String(contentsOf: repo.appendingPathComponent("Sources/DAWAppKit/SingSheetModel.swift"),
                               encoding: .utf8)
        #expect(!wire.contains("own.range = record.range"), "the range is set in SingVoiceLibrary.ownVoice only")
        #expect(wire.contains("library.ownVoice(record)"))
        #expect(sheet.contains(".own(library.ownVoice(record))"), "positive control: the sheet's builder is the home's")
    }

    // MARK: - 2. The dry run previews parts

    @Test("SPY: a dry run's parts come from the coordinator's plan(_:) and nothing is submitted")
    func dryRunPartsComeFromPlan() async throws {
        let rig = try await spyRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let preview = try await MainActor.run { () -> SingJobCoordinator.PlanPreview in
            let plan = try rig.store.planSungVocal(clipId: rig.clipID, octaveShift: 0).plan
            return SingJobCoordinator.PlanPreview(plan: plan, parts: [], warnings: [])
        }
        await rig.jobs.setPreview(preview)
        let response = await call(rig.router, "sing.render", [
            "clipId": .string(rig.clipID.uuidString), "octaveShift": .number(0), "key": .number(0),
            "dryRun": .bool(true), "parts": .array([Self.third])])
        #expect(response.ok, "\(response.error ?? "")")
        #expect(response.result?["dryRun"]?.boolValue == true)
        #expect(response.result?["plan"]?["parts"]?.arrayValue?.isEmpty == true, "the coordinator's answer, as given")
        #expect(await rig.jobs.planned.count == 1, "the parts were planned by plan(_:), once")
        #expect(await rig.jobs.planned.first?.parts.count == 1)
        #expect(await rig.jobs.submitted.isEmpty, "a dry run submits nothing")
    }

    @Test("a dry run's parts equal the real submit's first plan.parts; the dry run queues nothing and changes nothing")
    func dryRunPartsEqualTheRealOnes() async throws {
        let rig = try await jobRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let params: [String: JSONValue] = [
            "clipId": .string(rig.clipID.uuidString), "octaveShift": .number(0), "key": .number(0),
            "parts": .array([Self.third, .object(["kind": .string("double")])])]
        let (tracksBefore, historyBefore) = await MainActor.run { (rig.store.tracks, rig.store.undoHistory()) }
        var dry = params
        dry["dryRun"] = .bool(true)
        let preview = await call(rig.router, "sing.render", dry)
        #expect(preview.ok, "\(preview.error ?? "")")
        let dryParts = try #require(preview.result?["plan"]?["parts"]?.arrayValue)
        #expect(dryParts.count == 3)
        #expect(preview.result?["partsNote"] == nil && preview.result?["plan"]?["partsNote"] == nil)
        #expect(await rig.coordinator.statuses(limit: 20).isEmpty, "nothing was queued")
        let (tracksAfter, historyAfter) = await MainActor.run { (rig.store.tracks, rig.store.undoHistory()) }
        #expect(tracksAfter == tracksBefore)
        #expect(historyAfter == historyBefore, "the undo stack and the redo stack are as they were")

        let real = await call(rig.router, "sing.render", params)
        #expect(real.ok, "\(real.error ?? "")")
        let realParts = try #require(real.result?["plan"]?["parts"]?.arrayValue)
        #expect(dryParts == realParts, "the preview is exactly what the job then plans")
        let jobID = try #require(real.result?["jobId"]?.stringValue)
        _ = await call(rig.router, "sing.cancelJob", ["jobId": .string(jobID)])
    }

    @Test("a dry run WITHOUT parts has no parts (S6); with parts and NEW words it previews the parts over them, exactly what the real submit then plans, and stores nothing (X7D: was partsNote)")
    func dryRunWithNewWords() async throws {
        let rig = try await jobRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let clip = JSONValue.string(rig.clipID.uuidString)
        let bare = await call(rig.router, "sing.render", ["clipId": clip, "octaveShift": .number(0),
                                                           "dryRun": .bool(true)])
        #expect(bare.ok)
        #expect(bare.result?["plan"]?["parts"] == nil && bare.result?["plan"]?["partsNote"] == nil)

        let params: [String: JSONValue] = [
            "clipId": clip, "octaveShift": .number(0), "key": .number(0),
            "lyrics": .string(Self.newWords), "parts": .array([Self.third, .object(["kind": .string("double")])])]
        let (before, historyBefore) = await MainActor.run { (rig.store.tracks, rig.store.undoHistory()) }
        var dry = params
        dry["dryRun"] = .bool(true)
        let withWords = await call(rig.router, "sing.render", dry)
        #expect(withWords.ok, "\(withWords.error ?? "")")
        let dryParts = try #require(withWords.result?["plan"]?["parts"]?.arrayValue)
        #expect(dryParts.count == 3)
        #expect(withWords.result?["plan"]?["partsNote"] == nil, "no note any more: the parts are previewed")
        #expect(withWords.result?["plan"]?["assignment"] != nil, "the lead's plan is over the NEW words")
        let (after, historyAfter) = await MainActor.run { (rig.store.tracks, rig.store.undoHistory()) }
        #expect(after == before && historyAfter == historyBefore, "the words and the undo and redo stacks are untouched")
        #expect(await lyricsText(rig) == SingWireFixture.twoUnitLyrics)
        #expect(await rig.coordinator.statuses(limit: 20).isEmpty, "nothing was queued")

        let real = await call(rig.router, "sing.render", params)
        #expect(real.ok, "\(real.error ?? "")")
        #expect(await lyricsText(rig) == Self.newWords, "the real request stored the words")
        let realParts = try #require(real.result?["plan"]?["parts"]?.arrayValue)
        #expect(dryParts == realParts, "the preview over new words is what the job then plans from the stored words")
        if let jobID = real.result?["jobId"]?.stringValue {
            _ = await call(rig.router, "sing.cancelJob", ["jobId": .string(jobID)])
        }
    }

    @Test("a clip with NO words yet: the dry run and the real request, both with parts and new words, plan the parts over the new words and agree (X7D)")
    func partsOverWordsTheClipLacks() async throws {
        let rig = try await jobRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        await MainActor.run {
            for t in rig.store.tracks.indices {
                if let c = rig.store.tracks[t].clips.firstIndex(where: { $0.id == rig.clipID }) {
                    rig.store.tracks[t].clips[c].lyrics = nil
                }
            }
        }
        let params: [String: JSONValue] = [
            "clipId": .string(rig.clipID.uuidString), "octaveShift": .number(0), "key": .number(0),
            "lyrics": .string(Self.newWords), "parts": .array([Self.third])]
        var dry = params
        dry["dryRun"] = .bool(true)
        let preview = await call(rig.router, "sing.render", dry)
        #expect(preview.ok, "the parts are planned over the NEW words, not the empty stored ones: \(preview.error ?? "")")
        let dryParts = preview.result?["plan"]?["parts"]?.arrayValue
        #expect(await lyricsText(rig) == nil, "the dry run stored nothing")
        let real = await call(rig.router, "sing.render", params)
        #expect(real.ok, "\(real.error ?? "")")
        #expect(dryParts != nil && dryParts == real.result?["plan"]?["parts"]?.arrayValue)
        if let jobID = real.result?["jobId"]?.stringValue {
            _ = await call(rig.router, "sing.cancelJob", ["jobId": .string(jobID)])
        }
    }

    @Test("SPY: with parts and new words the wire plans over them through plan(_:lyrics:) BEFORE storing; without parts it does not plan (X7D)")
    func planOverNewWordsBeforeStoring() async throws {
        let rig = try await spyRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let preview = try await MainActor.run { () -> SingJobCoordinator.PlanPreview in
            let plan = try rig.store.planSungVocal(clipId: rig.clipID, octaveShift: 0).plan
            return SingJobCoordinator.PlanPreview(plan: plan, parts: [], warnings: [])
        }
        await rig.jobs.setPreview(preview)
        let clip = JSONValue.string(rig.clipID.uuidString)
        let bare = await call(rig.router, "sing.render", ["clipId": clip, "octaveShift": .number(0),
                                                           "lyrics": .string(Self.newWords)])
        #expect(bare.ok, "\(bare.error ?? "")")
        #expect(await rig.jobs.planned.isEmpty, "no parts: the base verb, no extra planning")
        // Put the words back so the next request has new words to send.
        await MainActor.run {
            for t in rig.store.tracks.indices {
                if let c = rig.store.tracks[t].clips.firstIndex(where: { $0.id == rig.clipID }) {
                    rig.store.tracks[t].clips[c].lyrics = ClipLyrics(text: SingWireFixture.twoUnitLyrics)
                }
            }
        }
        let withParts = await call(rig.router, "sing.render", [
            "clipId": clip, "octaveShift": .number(0), "key": .number(0),
            "lyrics": .string(Self.newWords), "parts": .array([Self.third])])
        #expect(withParts.ok, "\(withParts.error ?? "")")
        #expect(await rig.jobs.planned.count == 1)
        let sent = await rig.jobs.plannedLyrics
        #expect(sent.count == 1 && sent[0] != nil, "the plan call carried the new words")
        if let words = sent.first, let checked = words {
            #expect(checked?.text == Self.newWords)
        }
    }

    @Test("the override is the SAME planner: planSungVocal(lyrics: nil) is the old function; plan(_:lyrics: x) equals plan(_:) once x is stored (X7D)")
    func overrideIsTheSamePlanner() async throws {
        let rig = try await jobRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let words = ClipLyrics(text: Self.newWords)
        let (oldWay, nilWay, overridden) = try await MainActor.run { () -> (SungVocalPlanning, SungVocalPlanning, SungVocalPlanning) in
            (try rig.store.planSungVocal(clipId: rig.clipID, octaveShift: 0),
             try rig.store.planSungVocal(clipId: rig.clipID, octaveShift: 0, lyrics: nil),
             try rig.store.planSungVocal(clipId: rig.clipID, octaveShift: 0, lyrics: .some(words)))
        }
        #expect(nilWay == oldWay, "lyrics: nil is the existing function, property for property")
        #expect(overridden.plan != oldWay.plan, "the new words change the plan")
        #expect(await lyricsText(rig) == SingWireFixture.twoUnitLyrics, "planning stored nothing")

        let request = SingJobRequest(
            clipID: rig.clipID, octaveShift: 0, voice: .builtIn, seed: nil, trackName: nil, fromAgent: true,
            parts: [SingJobPart(.double)], key: nil)
        let over = try await rig.coordinator.plan(request, lyrics: .some(words))
        await MainActor.run {
            for t in rig.store.tracks.indices {
                if let c = rig.store.tracks[t].clips.firstIndex(where: { $0.id == rig.clipID }) {
                    rig.store.tracks[t].clips[c].lyrics = words
                }
            }
        }
        let stored = try await rig.coordinator.plan(request)
        #expect(over == stored, "planning over x equals planning after x is stored")
        #expect(over.plan == overridden.plan)
    }

    // MARK: - 3. A refused parts request changes nothing

    @Test("every coordinator part refusal WITH new lyrics keeps its code and words, and leaves the clip's words, its undo stack and the queue alone")
    func refusedPartsChangeNothing() async throws {
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
        // The user's own redo entry: an edit, then its undo. A refused request must leave it exactly where it is.
        try await MainActor.run {
            _ = rig.store.addTrack(kind: .instrument)
            _ = try rig.store.undo()
        }
        let seeded = await MainActor.run { rig.store.undoHistory() }
        #expect(seeded.redo.first != nil && seeded.redo.first != "Set Lyrics", "the user's redo entry is in place")
        let parts: [JSONValue] = [
            .object(["kind": .string("double"), "pan": .number(1.5)]),
            .object(["kind": .string("double"), "volumeDb": .number(9)]),
            .object(["kind": .string("double"), "seed": .number(Double(SingJobRequestBuilder.firstTakeSeed))]),
            .object(["kind": .string("clip"), "sourceClipId": clip]),
            .object(["kind": .string("clip"), "sourceClipId": .string(UUID().uuidString)]),
            .object(["kind": .string("clip"), "sourceClipId": .string(other.uuidString)]),
        ]
        var codes: [String] = []
        for part in parts {
            let params: [String: JSONValue] = ["clipId": clip, "octaveShift": .number(0), "parts": .array([part])]
            // The refusal as it reads without new words, then with them: the same code and sentence.
            let plain = await call(rig.router, "sing.render", params)
            let (tracksBefore, historyBefore) = await MainActor.run { (rig.store.tracks, rig.store.undoHistory()) }
            var withWords = params
            withWords["lyrics"] = .string(Self.newWords)
            let refused = await call(rig.router, "sing.render", withWords)
            let error = try #require(refused.error, "\(part): a refusal")
            #expect(error == plain.error, "\(part): same code and sentence")
            codes.append(String(error.prefix { $0 != ":" }))
            #expect(await lyricsText(rig) == SingWireFixture.twoUnitLyrics, "\(part): the clip's words are as they were")
            let (tracksAfter, historyAfter) = await MainActor.run { (rig.store.tracks, rig.store.undoHistory()) }
            #expect(tracksAfter == tracksBefore, "\(part)")
            #expect(historyAfter == historyBefore, "\(part): the undo stack AND the redo stack are as they were")
            #expect(historyAfter.redo == seeded.redo, "\(part): the user's redo entry survived")
            #expect(!historyAfter.redo.contains("Set Lyrics") && !historyAfter.undo.contains("Set Lyrics"),
                    "\(part): no Set Lyrics step, in either stack")
            #expect(await rig.coordinator.statuses(limit: 20).isEmpty, "\(part): nothing queued")
        }
        #expect(codes.contains("singPartClipNotFound") && codes.contains("singPartInvalid")
                    && codes.contains("lyricsTooManyWords"), "\(codes): the cases span the coordinator's refusals")
    }

    @Test("a parts request that is NOT refused still stores the new words, as ONE undo step")
    func acceptedPartsRequestKeepsTheWords() async throws {
        let rig = try await jobRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let response = await call(rig.router, "sing.render", [
            "clipId": .string(rig.clipID.uuidString), "octaveShift": .number(0), "key": .number(0),
            "lyrics": .string(Self.newWords), "parts": .array([Self.third])])
        #expect(response.ok, "\(response.error ?? "")")
        #expect(await lyricsText(rig) == Self.newWords)
        #expect(await MainActor.run { rig.store.undoHistory().undo.first } == "Set Lyrics")
        if let jobID = response.result?["jobId"]?.stringValue {
            _ = await call(rig.router, "sing.cancelJob", ["jobId": .string(jobID)])
        }
    }
}
