import Foundation
import Testing
@testable import AIServices
@testable import DAWCore

// W8-XL (p2-sing-x6 follow-up; design docs/design/2026-10-06-p2-sing-expansion.md §7.1-§7.2, §9.2 S5): a word's
// language reaches the singing engine. A Chinese or Cantonese word goes out with its `lang`, and only then does the
// body say `facadeVersion: 2`; an English phrase is today's v1 body, byte for byte. Plus the two coordinator paths
// W8-X6 left untested: a part that fails WHILE it is being sung, and the style pass failing at assembly.
//
// Nonisolated on purpose (the tree is at its `@MainActor` suite cap): every store read goes through `MainActor.run`.
// ⚠️ No `Task.cancel()` anywhere: every wait polls.

enum SingLanguageFixture {
    /// Two notes, two words, built by hand so a pin depends on nothing but the builder.
    static func unit(_ words: [(text: String, language: String?)]) -> SingUnit {
        SingUnit(
            notes: [SingNote(noteID: UUID(), startSeconds: 0, endSeconds: 0.5, midi: 60, sourcePitch: 60),
                    SingNote(noteID: UUID(), startSeconds: 0.5, endSeconds: 1, midi: 62, sourcePitch: 62)],
            words: words.enumerated().map { i, word in
                SingWord(text: word.text, typed: word.text, noteIndices: [i], language: word.language)
            },
            offsetSeconds: 0, onsetSeconds: 2, spanSeconds: 1)
    }

    static func body(_ unit: SingUnit, outputPath: String) throws -> String {
        let request = SingJobRequestBuilder.phraseRequest(
            unit: unit, voice: .builtin(id: "builtin-1"), seed: SingJobRequestBuilder.firstTakeSeed,
            outputPath: outputPath)
        return String(decoding: try SingJobRequestBuilder.canonicalBody(request), as: UTF8.self)
    }

    /// Eight Han characters, one per note of the fixture's two four-note phrases.
    static let chineseLyrics = "一二三四\n五六七八"

    /// Writes `text` in `language` onto a clip directly, outside any undo step (as `SingFixture.setLyrics`).
    @MainActor
    static func setLyrics(_ store: ProjectStore, clipID: UUID, text: String, language: String?) throws {
        for t in store.tracks.indices {
            if let c = store.tracks[t].clips.firstIndex(where: { $0.id == clipID }) {
                store.tracks[t].clips[c].lyrics = ClipLyrics(text: text, language: language)
                return
            }
        }
        throw ProjectError.clipNotFound(clipID)
    }

    /// The `phrase.words` objects of a canonical body.
    static func words(of body: String) throws -> [[String: Any]] {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let phrase = try #require(object["phrase"] as? [String: Any])
        return try #require(phrase["words"] as? [[String: Any]])
    }

    static func facadeVersion(of body: String) throws -> Int? {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        return object["facadeVersion"] as? Int
    }
}

@Suite("SingJob language — a word's lang reaches the facade, v2 only when a word has one (W8-XL)")
struct SingJobLanguageTests {

    // MARK: The builder

    @Test("zh: every Chinese word carries lang zh and the body says facadeVersion 2, byte for byte (keys sorted)")
    func mandarinBodyIsPinned() throws {
        let body = try SingLanguageFixture.body(
            SingLanguageFixture.unit([("你", "zh"), ("hao3", "zh")]), outputPath: "/tmp/sing-zh.wav")
        #expect(body == #"{"cfg":3,"facadeVersion":2,"leadS":0.23999999999999999,"nSteps":32,"#
            + #""outputPath":"\/tmp\/sing-zh.wav","outputSampleRate":48000,"#
            + #""phrase":{"notes":[{"endS":0.5,"midi":60,"startS":0},{"endS":1,"midi":62,"startS":0.5}],"#
            + #""words":[{"lang":"zh","noteIndices":[0],"text":"你"},{"lang":"zh","noteIndices":[1],"text":"hao3"}]},"#
            + #""seed":20260924,"trailS":0.23999999999999999,"voice":{"id":"builtin-1"}}"#)
    }

    @Test("yue: every Cantonese word carries lang yue and the body says facadeVersion 2, byte for byte")
    func cantoneseBodyIsPinned() throws {
        let body = try SingLanguageFixture.body(
            SingLanguageFixture.unit([("你", "yue"), ("hou2", "yue")]), outputPath: "/tmp/sing-yue.wav")
        #expect(body == #"{"cfg":3,"facadeVersion":2,"leadS":0.23999999999999999,"nSteps":32,"#
            + #""outputPath":"\/tmp\/sing-yue.wav","outputSampleRate":48000,"#
            + #""phrase":{"notes":[{"endS":0.5,"midi":60,"startS":0},{"endS":1,"midi":62,"startS":0.5}],"#
            + #""words":[{"lang":"yue","noteIndices":[0],"text":"你"},{"lang":"yue","noteIndices":[1],"text":"hou2"}]},"#
            + #""seed":20260924,"trailS":0.23999999999999999,"voice":{"id":"builtin-1"}}"#)
    }

    @Test("English: no lang and facadeVersion 1, the SAME bytes as the old init's request; a literal \"en\" is English")
    func englishStaysV1() throws {
        let english = SingLanguageFixture.unit([("twin", nil), ("kle", nil)])
        let literal = SingLanguageFixture.unit([("twin", "en"), ("kle", "en")])
        let built = try SingLanguageFixture.body(english, outputPath: "/tmp/sing-en.wav")
        // The request as it was built before languages: the two-argument word init.
        let old = SingingPhraseRequest(
            voice: .builtin(id: "builtin-1"),
            notes: english.notes.map { SingingPhraseNote(startS: $0.startSeconds, endS: $0.endSeconds, midi: $0.midi) },
            words: english.words.map { SingingPhraseWord(text: $0.text, noteIndices: $0.noteIndices) },
            leadS: SingPlanner.leadSeconds, trailS: SingPlanner.trailSeconds, seed: SingJobRequestBuilder.firstTakeSeed,
            nSteps: SingRenderOptions.v1.nSteps, cfg: SingRenderOptions.v1.cfg, outputPath: "/tmp/sing-en.wav",
            outputSampleRate: SingJobRequestBuilder.defaultOutputSampleRate)
        #expect(built == String(decoding: try SingJobRequestBuilder.canonicalBody(old), as: UTF8.self))
        #expect(try SingLanguageFixture.body(literal, outputPath: "/tmp/sing-en.wav") == built)
        #expect(try SingLanguageFixture.facadeVersion(of: built) == 1)
        #expect(!built.contains("\"lang\""))
        #expect(!built.contains("\"control\""), "control is optional in v2 (default score): never sent")
    }

    @Test("mixed: a Chinese clip's English word sends no lang; the body is v2 because one word has one")
    func mixedSendsLangOnlyWhereSet() throws {
        let body = try SingLanguageFixture.body(SingLanguageFixture.unit([("我", "zh"), ("love", nil)]),
                                                outputPath: "/tmp/sing-mix.wav")
        let words = try SingLanguageFixture.words(of: body)
        #expect(words.map { $0["lang"] as? String } == ["zh", nil])
        #expect(Set(words[1].keys) == ["text", "noteIndices"], "an English word is the v1 word")
        #expect(try SingLanguageFixture.facadeVersion(of: body) == 2)
    }

    @Test("v2 keys: the top level is exactly schema.py's TOP_KEYS; a word only adds V2_WORD_KEYS' lang")
    func v2KeysAreTheFacadesKeys() {
        let request = SingJobRequestBuilder.phraseRequest(
            unit: SingLanguageFixture.unit([("你", "zh"), ("好", "zh")]), voice: .builtin(id: "builtin-1"), seed: 1,
            outputPath: "/tmp/x.wav")
        let object = request.jsonObject()
        // `scripts/sing/singlib/schema.py` TOP_KEYS / V2_TOP_KEYS / V2_WORD_KEYS, read 2026-10-07 (W8-XL).
        #expect(Set(object.keys) == ["facadeVersion", "voice", "phrase", "leadS", "trailS", "seed", "nSteps", "cfg",
                                     "outputPath", "outputSampleRate"])
        #expect(request.bodyFacadeVersion == 2)
        for word in request.words { #expect(Set(word.jsonObject.keys) == ["text", "noteIndices", "lang"]) }
    }

    @Test("cache key: the same text on the same notes gets a NEW key in Chinese; the English key is unchanged")
    func languageIsInTheCacheKey() throws {
        let engine = SingEngineIdentity(commit: "abc", weightsRevision: "w1", weightsBytes: 10, facadeVersion: 1)
        func key(_ language: String?) throws -> String {
            try SingJobRequestBuilder.cacheKey(
                for: SingJobRequestBuilder.phraseRequest(
                    unit: SingLanguageFixture.unit([("ni3", language), ("hao3", language)]),
                    voice: .builtin(id: "builtin-1"), seed: 7, outputPath: "/tmp/k.wav"),
                engine: engine)
        }
        let english = try key(nil)
        let mandarin = try key("zh")
        let cantonese = try key("yue")
        #expect(Set([english, mandarin, cantonese]).count == 3, "a language never shares another's key")
        #expect(try key("en") == english)
        // The English key hashes exactly the old (two-argument) words, so every cached English phrase stays a hit.
        let unit = SingLanguageFixture.unit([("ni3", nil), ("hao3", nil)])
        let old = SingingPhraseRequest(
            voice: .builtin(id: "builtin-1"),
            notes: unit.notes.map { SingingPhraseNote(startS: $0.startSeconds, endS: $0.endSeconds, midi: $0.midi) },
            words: unit.words.map { SingingPhraseWord(text: $0.text, noteIndices: $0.noteIndices) },
            leadS: SingPlanner.leadSeconds, trailS: SingPlanner.trailSeconds, seed: 7,
            nSteps: SingRenderOptions.v1.nSteps, cfg: SingRenderOptions.v1.cfg, outputPath: "/tmp/other.wav",
            outputSampleRate: SingJobRequestBuilder.defaultOutputSampleRate)
        #expect(try SingJobRequestBuilder.cacheKey(for: old, engine: engine) == english)
    }

    // MARK: The job (the fake synthesizer's captured bodies)

    /// Runs a default job on the fixture's eight notes sung in `language` (Han lyrics); returns the bodies + keys.
    static func chineseJob(_ label: String, language: String) async throws -> (SingJobStatus, [String], [String]) {
        let h = try await SingPartsHarness.make(label)
        defer { h.cleanup() }
        try await MainActor.run {
            try SingLanguageFixture.setLyrics(h.store, clipID: h.clipID, text: SingLanguageFixture.chineseLyrics,
                                              language: language)
        }
        let done = try await h.run(SingJobRequest(clipID: h.clipID))
        return (done, try await h.bodies(), await h.cacheKeys())
    }

    @Test("a Chinese clip's job (zh, then yue) sends v2 bodies with its lang on EVERY word", arguments: ["zh", "yue"])
    func chineseJobSendsLangOnEveryWord(language: String) async throws {
        let (done, bodies, _) = try await Self.chineseJob("lang-\(language)", language: language)
        #expect(done.phase == .done, "\(done.error?.message ?? "") \(done.error?.detail ?? "")")
        #expect(bodies.count == 2, "two phrases, two requests")
        var texts: [String] = []
        for body in bodies {
            #expect(try SingLanguageFixture.facadeVersion(of: body) == 2, "\(body)")
            let words = try SingLanguageFixture.words(of: body)
            #expect(!words.isEmpty)
            for word in words { #expect(word["lang"] as? String == language, "\(word)") }
            texts += words.compactMap { $0["text"] as? String }
            #expect(!body.contains("\"control\""))
        }
        #expect(texts == "一二三四五六七八".map(String.init), "one Han character per word, in order")
    }

    @Test("the cache keys of an English job and a Chinese job of the SAME notes differ; the English ones are S5's")
    func englishAndChineseJobsHaveDifferentKeys() async throws {
        let english = try await SingPartsHarness.make("keys-en")
        defer { english.cleanup() }
        let e = try await english.run(SingJobRequest(clipID: english.clipID))
        #expect(e.phase == .done, "\(e.error?.message ?? "")")
        let englishKeys = await english.cacheKeys()
        let (c, _, chineseKeys) = try await Self.chineseJob("keys-zh", language: "zh")
        #expect(c.phase == .done, "\(c.error?.message ?? "")")
        #expect(englishKeys == SingJobPartsTests.goldenKeys, "an English job's keys are the S5 pin-before keys")
        #expect(chineseKeys.count == 2 && englishKeys.count == 2)
        #expect(Set(englishKeys).isDisjoint(with: chineseKeys), "\(englishKeys) vs \(chineseKeys)")
    }

    // MARK: The orphan prune before isNoOp

    @Test("styleForNoOpCheck: orphan-only choices prune to no style; a held note's choice and the clip-wide ones stay")
    func noOpCheckPrunesOrphansOnly() {
        let held = UUID(), ghost = UUID()
        let orphanOnly = SingStyle(notes: [ghost: NoteSingStyle(vibrato: .wide, air: 1)])
        #expect(SingJobCoordinator.styleForNoOpCheck(orphanOnly, heldNoteIDs: [held]) == nil)
        // W9-PICKS (round V): pruned to no style, it sings the DEFAULT vibrato (Normal), so it is not a no-op; the
        // same orphans under a named As sung prune to As sung, which is.
        #expect(!SungExpressionPlanner.isNoOp(style: SingJobCoordinator.styleForNoOpCheck(orphanOnly, heldNoteIDs: [held])))
        let orphanAsSung = SingStyle(vibrato: .asSung, notes: [ghost: NoteSingStyle(vibrato: .wide, air: 1)])
        #expect(SingJobCoordinator.styleForNoOpCheck(orphanAsSung, heldNoteIDs: [held]) == SingStyle(vibrato: .asSung))
        #expect(SungExpressionPlanner.isNoOp(style: SingJobCoordinator.styleForNoOpCheck(orphanAsSung, heldNoteIDs: [held])))
        #expect(!SungExpressionPlanner.isNoOp(style: orphanAsSung), "unpruned, the same style is not a no-op")
        let mixed = SingStyle(air: 0.5, notes: [held: NoteSingStyle(vibrato: .wide), ghost: NoteSingStyle(air: 1)])
        #expect(SingJobCoordinator.styleForNoOpCheck(mixed, heldNoteIDs: [held])
                == SingStyle(air: 0.5, notes: [held: NoteSingStyle(vibrato: .wide)]))
        #expect(SingJobCoordinator.styleForNoOpCheck(nil, heldNoteIDs: [held]) == nil)
    }

    // MARK: A part that fails WHILE it is being sung (W8-X6 left this untested)

    enum InFlightFault: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case badAfterRetry, facadeRefusal
        var testDescription: String { rawValue }
    }

    @Test("a harmony part that fails while sung fails ONLY that part; the lead and the double land in ONE undo",
          arguments: InFlightFault.allCases)
    func partFailingWhileSungFailsOnlyThatPart(fault: InFlightFault) async throws {
        let h = try await SingPartsHarness.make("inflight-\(fault.rawValue)")
        defer { h.cleanup() }
        // Calls per word go lead, harmony, double. The harmony's FIRST line goes wrong while it is sung.
        switch fault {
        case .badAfterRetry:
            await h.synth.plan("one", [.sung(.sine), .facadeNonFinite, .facadeNonFinite])
        case .facadeRefusal:
            await h.synth.plan("one", [.sung(.sine), .refusal(.unknownPhone("No phone for that word."))])
        }
        let tracksBefore = await MainActor.run { h.store.tracks }
        let undoBefore = await MainActor.run { h.store.undoHistory().undo.count }
        let done = try await h.run(SingJobRequest(clipID: h.clipID, parts: [SingJobPartsTests.thirdAbove,
                                                                             SingJobPart(.double)],
                                                  key: SingJobPartsTests.cMajor))
        #expect(done.phase == .done, "\(done.error?.message ?? "") \(done.error?.detail ?? "")")
        #expect(done.parts?.map(\.state) == [.landed, .failed, .landed])
        let failed = try #require(done.parts?[1])
        #expect(failed.error?.code == (fault == .badAfterRetry ? "singBadUnit" : "singFacadeRefused"))
        #expect(failed.error?.message == "The part 'third above' didn't come out right.")
        #expect(failed.trackID == nil)
        #expect(done.notices.contains("The part 'third above' didn't come out right."))
        #expect(done.result?.trackID == done.parts?[0].trackID, "the job's result is the lead's")
        // The harmony's second line is never sung once its first failed; the double sings both of its lines.
        let calls = await h.synth.calls(for: "five")
        #expect(calls.count == 2, "lead and double only: \(calls.map(\.seed))")
        #expect(await MainActor.run { h.store.tracks.count } == tracksBefore.count + 2)
        #expect(await MainActor.run { h.store.undoHistory().undo.count } == undoBefore + 1)
        #expect(try await MainActor.run { try h.store.undo() } == "Land Sung Harmony")
        #expect(await MainActor.run { h.store.tracks } == tracksBefore)
    }

    // MARK: The style pass failing at assembly

    /// `SungExpressionPlanner.plan` is a static call with NO seam, so "plan throws" itself cannot be planted here.
    /// Detection, notes-do-not-match and the planner share ONE `.failure` arm in `finishPart`; this drives that arm
    /// through the `detectPitch` seam (the pre-air call throws).
    @Test("the style pass failing (the pre-air detection throws) lands the take WITHOUT the style, with the warning")
    func stylePassFailureLandsWithoutStyle() async throws {
        let h = try await SingPartsHarness.make("style-fails")
        defer { h.cleanup() }
        _ = try await MainActor.run {
            try SingPartsFixture.lengthen(h.store, clipID: h.clipID) { _ in SingStyle(vibrato: .wide, air: 1) }
        }
        await h.detector.failPreAir()
        let done = try await h.run(SingJobRequest(clipID: h.clipID))
        #expect(done.phase == .done, "\(done.error?.message ?? "")")
        #expect(done.warnings == [SingJobCoordinator.Copy.styleNotApplied], "\(done.warnings)")
        let files = await h.detector.files
        #expect(files.count == 2 && files.first?.hasSuffix("-preair.wav") == true, "\(files)")
        let track = try #require(await h.track(done.result?.trackID))
        #expect(track.clips.first?.pitchEdits == nil, "no table: the take is sung as is")
        #expect(track.sungVocalProvenance != nil)
        #expect(track.sungVocalProvenance?.style == nil, "the record says no style was applied")
        let takes = h.cache.directory.appendingPathComponent("takes").path
        let left = (try? FileManager.default.contentsOfDirectory(atPath: takes)) ?? []
        #expect(!left.contains { $0.hasSuffix("-preair.wav") }, "the pre-air file is removed on the failure path too")
    }
}

// MARK: - The real stub facade accepts the v2 body

/// Keeps every request it forwards to the real HTTP client.
actor RecordingSingClient: SingingSynthesizing {
    let inner: SingingSynthesisClient
    private(set) var requests: [SingingPhraseRequest] = []

    init(inner: SingingSynthesisClient) { self.inner = inner }

    func renderPhrase(_ request: SingingPhraseRequest) async throws -> SingingRenderResult {
        requests.append(request)
        return try await inner.renderPhrase(request)
    }
}

/// ⚠️ The shape the singing-sidecar tests keep (`SingJobStubSidecarTests`): ONE manager, no eviction, no side task
/// polling the manager; the stub (`SING_USE_STUB=1`, never the real engine) on an ephemeral TEST port, never 8004.
@Suite("SingJob language — the stub facade accepts a Chinese v2 body over HTTP (W8-XL)")
struct SingJobLanguageStubTests {

    @Test("a zh job through the real stub: v2 bodies with lang zh render and land; the same body as v1 is refused")
    func stubAcceptsChineseV2Body() async throws {
        let root = try SingFixture.tempDir("xl-stub")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        let voices = root.appendingPathComponent("voices", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        for dir in [runtime, voices, cacheDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: runtime.appendingPathComponent("install.json"))
        let scripts = try #require(
            SingingSidecarManager.Configuration.resolveScriptsDir(environment: ProcessInfo.processInfo.environment),
            "scripts/sing could not be resolved from this test process")
        let port = try StubACEStepServer.unusedLoopbackPort()
        #expect(port != 8004 && port != 17600)
        let base = URL(string: "http://127.0.0.1:\(port)")!

        let lifecycle = ModelLifecycleCoordinator(
            storageDirectory: root.appendingPathComponent("lifecycle", isDirectory: true), settleSeconds: 0)
        var soulx = ModelRegistry.soulxSinger(baseURL: base)
        soulx.idleUnloadSeconds = nil
        await lifecycle.register(soulx, evictor: nil)
        var config = SingingSidecarManager.Configuration(
            baseURL: base, scriptsDir: scripts, runtimeDir: runtime, voicesDir: voices, cacheDir: cacheDir,
            startupTimeoutSeconds: 15, healthPollIntervalSeconds: 0.1, healthProbeTimeoutSeconds: 2,
            stopTimeoutSeconds: 5, lifecycle: lifecycle, logFileURL: root.appendingPathComponent("sing.log"))
        config.testExtraEnvironment = ["SING_USE_STUB": "1"]
        config.watchdogReadMemoryPressureCritical = { false }
        let manager = SingingSidecarManager(configuration: config)

        let (store, clipID) = try await MainActor.run { try SingFixture.store(root: root) }
        try await MainActor.run {
            try SingLanguageFixture.setLyrics(store, clipID: clipID, text: SingLanguageFixture.chineseLyrics,
                                              language: "zh")
        }
        let client = RecordingSingClient(inner: SingingSynthesisClient(baseURL: base))
        let coordinator = SingJobCoordinator(
            store: store, engine: manager, synthesizer: client,
            lifecycle: lifecycle, cache: SingPhraseCache(directory: cacheDir),
            detectPitch: { url in try SingFixture.frames(at: url) },
            transcribe: { _ in "一二三四五六七八" },
            configuration: SingJobCoordinator.Configuration(
                outputSampleRate: 48_000, modelPollSeconds: 0.05, enginePollSeconds: 0.05,
                sleepSeconds: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) },
                songGeneratorRunsOutside: { false }))

        do {
            let submitted = try await coordinator.submit(SingJobRequest(clipID: clipID))
            let finished = await SingFixture.waitUntil(60) {
                (try? await coordinator.status(jobID: submitted.jobID).phase.isTerminal) ?? false
            }
            let status = try await coordinator.status(jobID: submitted.jobID)
            #expect(finished, "the job reads \(status.phase): \(status.stageText)")
            #expect(status.phase == .done, "\(status.error?.message ?? "") \(status.error?.detail ?? "")")
            #expect(status.renderedUnits == 2)
            #expect(status.retriedUnits.isEmpty)
            let result = try #require(status.result)
            #expect(result.gates.failed.isEmpty, "\(result.gates)")

            // What the stub accepted: v2 bodies with lang zh on every word.
            let sent = await client.requests
            #expect(sent.count == 2)
            for request in sent {
                #expect(request.bodyFacadeVersion == 2)
                #expect(request.words.allSatisfy { $0.lang == "zh" })
                #expect(request.jsonObject()["facadeVersion"] as? Int == 2)
            }

            // Negative control: the SAME body under facadeVersion 1 is refused, so the stub really read `lang`.
            let first = try #require(sent.first)
            var v1 = first.jsonObject()
            v1["facadeVersion"] = 1
            var http = URLRequest(url: base.appendingPathComponent("v1/sing/phrase"))
            http.httpMethod = "POST"
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            http.httpBody = try JSONSerialization.data(withJSONObject: v1)
            let (data, response) = try await URLSession.shared.data(for: http)
            #expect((response as? HTTPURLResponse)?.statusCode == 400)
            let refusal = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(refusal?["error"] as? String == "badRequest", "\(String(decoding: data, as: UTF8.self))")
            #expect((refusal?["message"] as? String)?.contains("facadeVersion 2") == true,
                    "\(String(decoding: data, as: UTF8.self))")
            _ = try await manager.stop()
        } catch {
            _ = try? await manager.stop()
            throw error
        }
    }
}
