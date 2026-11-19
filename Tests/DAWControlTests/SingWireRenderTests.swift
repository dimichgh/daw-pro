import Foundation
import Testing
@testable import AIServices
@testable import DAWControl
@testable import DAWCore

/// p2-sing-e part 2: `sing.render`, `sing.jobStatus`, `sing.cancelJob` (design §6 rows 14–16). SPIES prove the wire
/// reaches `SingJobCoordinator.submit` (through `SingJobSubmitting`, the protocol the coordinator itself conforms to)
/// and, for `{lyrics}`, `ProjectStore.setClipLyrics` FIRST. The last test runs ONE take end to end through the wire
/// against the REAL coordinator and the stub sidecar (`SING_USE_STUB=1`, an ephemeral port, never the real engine).
@Suite("SingWire — sing.render / jobStatus / cancelJob reach the coordinator (p2-sing-e)")
struct SingWireRenderTests {

    struct Rig {
        let router: CommandRouter
        let store: ProjectStore
        let clipID: UUID
        let jobs: SingWireFakeJobs
        let engine: SingWireFakeEngine
        let spy: SingWireLyricsSpy
        let log: SingWireCallLog
        let submitted: SingWireCallLog
    }

    private func rig(lyrics: String? = SingWireFixture.twoUnitLyrics,
                     state: SingingSidecarState = .installedNotRunning) async throws -> Rig {
        let root = try SingWireFixture.tempDir("render")
        let base = URL(string: "http://127.0.0.1:\(try SingWireFixture.unusedLoopbackPort())")!
        let lifecycle = await SingWireFixture.lifecycle(root, baseURL: base)
        let engine = SingWireFakeEngine(config: SingWireFixture.config(root: root, baseURL: base, lifecycle: lifecycle),
                                        state: state)
        let log = SingWireCallLog()
        let submitted = SingWireCallLog()
        let jobs = SingWireFakeJobs(log: log)
        let probe = SingWireInstallProbe()
        let trash = SingWireFixture.trash(into: root)
        return try await MainActor.run {
            let (store, clipID) = try SingWireFixture.store(root: root, lyrics: lyrics)
            let spy = SingWireLyricsSpy(store: store, log: log)
            let services = SingWireFixture.services(root: root, engine: engine, jobs: jobs,
                                                    installFunction: probe.function, trash: trash)
            let router = CommandRouter(store: store, singServices: services, singLyrics: spy)
            router.singJobSubmitted = { status, label in submitted.append("\(status.jobID)|\(label)") }
            return Rig(router: router, store: store, clipID: clipID, jobs: jobs, engine: engine, spy: spy, log: log,
                       submitted: submitted)
        }
    }

    private func call(_ rig: Rig, _ verb: String, _ params: [String: JSONValue] = [:]) async -> ControlResponse {
        await rig.router.handle(SingWireFixture.request(verb, params))
    }

    private func keys(_ value: JSONValue?) -> Set<String> { Set(value?.objectValue.map { Array($0.keys) } ?? []) }

    @Test("SPY: sing.render submits ONE request to the coordinator — octave auto resolved, fromAgent, the card told")
    func renderSubmitsToTheCoordinator() async throws {
        let rig = try await rig()
        let response = await call(rig, "sing.render", ["clipId": .string(rig.clipID.uuidString),
                                                       "trackName": .string("Lead vocal"), "seed": .number(7)])
        #expect(response.ok, "\(response.error ?? "")")
        let requests = await rig.jobs.submitted
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.clipID == rig.clipID)
        #expect(request.voice == .builtIn)
        #expect(request.seed == 7)
        #expect(request.trackName == "Lead vocal")
        #expect(request.fromAgent)
        #expect(request.songTransposeSemitones == 0, "a render never changes the song's key")
        let expectedShift = try await MainActor.run { () -> Int in
            let clip = try #require(rig.store.tracks.flatMap(\.clips).first { $0.id == rig.clipID })
            let melody = SingWireHandlers.melodyForFit(clip, tempoMap: rig.store.transport.tempoMap)
            return try #require(VoiceRangeFit.propose(melody: melody, voice: SingVoiceLibrary.builtInRange))
                .bestOctaveOnly.octaveShift
        }
        #expect(request.octaveShift == expectedShift)
        #expect(response.result?["jobId"]?.stringValue == "sing-test-1")
        #expect(rig.submitted.calls == ["sing-test-1|Singing — Built-in singer"], "the progress card, as .sing")
        #expect(await MainActor.run { rig.spy.calls.isEmpty }, "no lyrics param, no lyrics write")
        // S6 pin-before (x7 must keep these keys without its new params).
        #expect(keys(response.result) == ["jobId", "plan", "status"])
        #expect(keys(response.result?["plan"]) == ["clipId", "voice", "octaveShift", "octaveChoice", "units",
                                                    "assignment", "warnings", "estimatedSeconds", "engine"])
    }

    @Test("SPY: sing.render {lyrics} stores them through setClipLyrics FIRST (its own undo step), then submits")
    func renderWithLyricsStoresThemFirst() async throws {
        let rig = try await rig(lyrics: nil)
        let response = await call(rig, "sing.render", ["clipId": .string(rig.clipID.uuidString),
                                                       "lyrics": .string(SingWireFixture.twoUnitLyrics),
                                                       "octaveShift": .number(-1)])
        #expect(response.ok, "\(response.error ?? "")")
        #expect(await MainActor.run { rig.spy.calls }
            == [.init(clipId: rig.clipID, text: SingWireFixture.twoUnitLyrics, undoLabel: "Set Lyrics")])
        #expect(rig.log.calls == ["setClipLyrics", "submit"], "the words are stored BEFORE the job")
        #expect(await rig.jobs.submitted.first?.octaveShift == -1)
        #expect(try await MainActor.run { try rig.store.undo() } == "Set Lyrics")
    }

    @Test("dryRun plans only: the units, the words, the octave choice and an estimate; nothing stored or submitted")
    func dryRunPlansOnly() async throws {
        let rig = try await rig(lyrics: nil)
        let response = await call(rig, "sing.render", ["clipId": .string(rig.clipID.uuidString),
                                                       "lyrics": .string(SingWireFixture.twoUnitLyrics),
                                                       "dryRun": .bool(true)])
        #expect(response.ok, "\(response.error ?? "")")
        #expect(keys(response.result) == ["dryRun", "plan"])
        let units = response.result?["plan"]?["units"]?.arrayValue ?? []
        #expect(units.count == 2)
        #expect(units.first?["words"]?.arrayValue == ["one", "two", "three", "four"].map(JSONValue.string))
        #expect(response.result?["plan"]?["octaveChoice"]?["auto"]?.boolValue == true)
        #expect(response.result?["plan"]?["engine"]?["needsStart"]?.boolValue == true)
        #expect(response.result?["plan"]?["engine"]?["needsInstall"]?.boolValue == false)
        #expect((response.result?["plan"]?["estimatedSeconds"]?.doubleValue ?? 0) >= 20, "a cold start is included")
        #expect(await rig.jobs.submitted.isEmpty)
        #expect(await MainActor.run { rig.spy.calls.isEmpty })
    }

    @Test("every refusal reads \"<code>: <sentence>\" exactly; none of them stores lyrics or submits")
    func renderRefusals() async throws {
        let rig = try await rig(lyrics: nil)
        let clip = JSONValue.string(rig.clipID.uuidString)
        let octave = "singOctaveShiftInvalid: A vocal can only move by whole octaves on its own; to change the "
            + "song's key use project.transpose."
        let unknown = UUID()
        let (audioClip, emptyClip) = try await MainActor.run { () -> (UUID, UUID) in
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent("sing-wire-\(UUID()).wav")
            try SingWAV.writeFloat32Mono([Float](repeating: 0, count: 4_800), sampleRate: 48_000, to: wav)
            let audio = try rig.store.importAudio(url: wav, toTrack: rig.store.addTrack(kind: .audio).id, atBeat: 0).id
            let empty = try rig.store.addMIDIClip(toTrack: rig.store.addTrack(kind: .instrument).id, atBeat: 0,
                                                  lengthBeats: 4).id
            return (audio, empty)
        }
        let cases: [([String: JSONValue], String)] = [
            (["clipId": clip, "octaveShift": .number(3)], octave),
            (["clipId": clip, "octaveShift": .number(1.5)], octave),
            (["clipId": clip, "octaveShift": .string("up")], octave),
            (["clipId": clip, "voiceId": .string("voice-nope")],
             "singVoiceNotFound: There is no voice \"voice-nope\". Call sing.listVoices to see the voices you can use."),
            (["clipId": clip], "singNeedsLyrics: Type the words you want me to sing."),
            (["clipId": clip, "lyrics": .string("one two three four five\nfive six seven eight")],
             "lyricsTooManyWords: This line has 5 words but the tune has 4 notes. Each note sings one word, so "
                 + "remove 1 word or add 1 note."),
            (["clipId": .string(audioClip.uuidString), "lyrics": .string("la")],
             "singNeedsMIDIClip: Sing needs a melody clip with notes. This one is audio."),
            (["clipId": .string(emptyClip.uuidString), "lyrics": .string("la")],
             "singClipHasNoNotes: This clip has no notes to sing. Add the tune first, then the words."),
            (["clipId": .string(unknown.uuidString)],
             "clipNotFound: No clip with id \(unknown.uuidString) — pick a melody clip that is in the song."),
            (["clipId": clip, "seed": .number(-1)],
             "singSeedInvalid: seed must be a whole number from 0 to 9007199254740991."),
        ]
        for (params, expected) in cases {
            #expect(await call(rig, "sing.render", params).error == expected, "\(params)")
        }
        #expect(await rig.jobs.submitted.isEmpty)
        #expect(await MainActor.run { rig.spy.calls.isEmpty })

        // The coordinator's own refusal passes through in its words; lyrics given with it ARE stored first (their
        // own undo step), because the render was well-formed until the queue said no.
        await rig.jobs.refuseSubmits(.queueFull(capacity: 4))
        #expect(await call(rig, "sing.render", ["clipId": clip, "lyrics": .string(SingWireFixture.twoUnitLyrics)]).error
            == "singQueueFull: 4 takes are already waiting to be sung. Wait for one to finish, then try again.")
    }

    @Test("an engine that is not installed is refused BEFORE the lyrics are stored")
    func notInstalledRefusesBeforeStoring() async throws {
        let rig = try await rig(lyrics: nil, state: .notInstalled)
        let response = await call(rig, "sing.render", ["clipId": .string(rig.clipID.uuidString),
                                                       "lyrics": .string(SingWireFixture.twoUnitLyrics)])
        #expect(response.error == "singEngineNotInstalled: fake engine: notInstalled")
        #expect(await MainActor.run { rig.spy.calls.isEmpty })
        #expect(await rig.jobs.submitted.isEmpty)
        let dry = await call(rig, "sing.render", ["clipId": .string(rig.clipID.uuidString),
                                                  "lyrics": .string(SingWireFixture.twoUnitLyrics),
                                                  "dryRun": .bool(true)])
        #expect(dry.result?["plan"]?["engine"]?["needsInstall"]?.boolValue == true, "\(dry.error ?? "")")
    }

    @Test("jobStatus and cancelJob read the coordinator; the reply keys are pinned; unknown and finished jobs refuse in words")
    func jobStatusAndCancel() async throws {
        let rig = try await rig()
        _ = await call(rig, "sing.render", ["clipId": .string(rig.clipID.uuidString)])
        let status = await call(rig, "sing.jobStatus", ["jobId": .string("sing-test-1")])
        #expect(status.ok, "\(status.error ?? "")")
        #expect(keys(status.result) == [
            "jobId", "clipId", "state", "phase", "stageText", "unit", "progress", "etaSeconds", "waitingFor",
            "cancelRequested", "seed", "warnings", "notices", "retriedUnits", "cachedUnits", "renderedUnits", "yields",
            "engineRestarts", "result", "gates", "error", "keptTakePath", "fromAgent", "submittedAt", "finishedAt"])
        #expect(status.result?["state"]?.stringValue == "queued")
        let recent = await call(rig, "sing.jobStatus")
        #expect(recent.result?["jobs"]?.arrayValue?.count == 1)
        #expect(await call(rig, "sing.jobStatus", ["jobId": .string("nope")]).error
            == "singJobNotFound: No sing job with id \"nope\" — sing.jobStatus with no id lists the recent ones.")

        let cancelled = await call(rig, "sing.cancelJob", ["jobId": .string("sing-test-1")])
        #expect(cancelled.result?["cancelRequested"]?.boolValue == true, "\(cancelled.error ?? "")")
        #expect(await rig.jobs.cancelled == ["sing-test-1"])
        await rig.jobs.hold([SingWireFakeJobs.status(id: "sing-done", phase: .done)])
        #expect(await call(rig, "sing.cancelJob", ["jobId": .string("sing-done")]).error
            == "singJobFinished: The sing job \"sing-done\" has already finished or landed, so there is nothing to "
                + "stop. Undo removes a take that landed.")
    }

    // MARK: - One take, end to end, through the WIRE (the SE1 stubRenderLandUndo precedent)

    @Test("STUB: sing.render {lyrics} → poll sing.jobStatus → landed take → undo twice restores the song; sing.sidecarStop proves the stop")
    func stubRenderLandUndoThroughTheWire() async throws {
        let root = try SingWireFixture.tempDir("stub")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("SingingEngine", isDirectory: true)
        let voices = root.appendingPathComponent("voices", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        for dir in [runtime, voices, cacheDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: runtime.appendingPathComponent("install.json"))
        let scripts = try #require(
            SingingSidecarManager.Configuration.resolveScriptsDir(environment: ProcessInfo.processInfo.environment),
            "scripts/sing could not be resolved from this test process")
        let port = try SingWireFixture.unusedLoopbackPort()
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let lifecycle = await SingWireFixture.lifecycle(root, baseURL: base)
        var config = SingingSidecarManager.Configuration(
            baseURL: base, scriptsDir: scripts, runtimeDir: runtime, voicesDir: voices, cacheDir: cacheDir,
            startupTimeoutSeconds: 15, healthPollIntervalSeconds: 0.1, healthProbeTimeoutSeconds: 2,
            stopTimeoutSeconds: 5, lifecycle: lifecycle, logFileURL: root.appendingPathComponent("sing.log"))
        config.testExtraEnvironment = ["SING_USE_STUB": "1", "SING_TEST_HOOKS": "1"]
        config.watchdogReadMemoryPressureCritical = { false }
        let manager = SingingSidecarManager(configuration: config)

        let (store, clipID) = try await MainActor.run { try SingWireFixture.store(root: root, lyrics: nil) }
        let tracksBefore = await MainActor.run { store.tracks }
        let coordinator = SingJobCoordinator(
            store: store, engine: manager, synthesizer: SingingSynthesisClient(baseURL: base),
            lifecycle: lifecycle, cache: SingPhraseCache(directory: cacheDir),
            detectPitch: { url in try SingWireStubPitch.frames(at: url) },
            transcribe: { _ in "one two three four five six seven eight" },
            configuration: SingJobCoordinator.Configuration(
                outputSampleRate: 48_000, modelPollSeconds: 0.05, enginePollSeconds: 0.05,
                sleepSeconds: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) },
                songGeneratorRunsOutside: { false }))
        let probe = SingWireInstallProbe()
        let router = await MainActor.run { () -> CommandRouter in
            let services = SingWireServices(
                engine: manager, jobs: coordinator,
                install: SingingEngineInstallCoordinator(installFunction: probe.function),
                consent: SingConsentBroker(autoConsent: false), voices: SingVoiceLibrary(root: voices),
                engineFiles: SingEngineFiles(config: config), lifecycle: lifecycle,
                detectPitch: { _, _ in [] }, transcribe: { _ in nil }, freeDiskBytes: { _ in nil },
                trash: SingWireFixture.trash(into: root), voiceCheckGuides: [:])
            return CommandRouter(store: store, singServices: services)
        }
        func wire(_ verb: String, _ params: [String: JSONValue] = [:]) async -> ControlResponse {
            await router.handle(SingWireFixture.request(verb, params))
        }

        do {
            let submitted = await wire("sing.render", ["clipId": .string(clipID.uuidString),
                                                       "lyrics": .string(SingWireFixture.twoUnitLyrics),
                                                       "octaveShift": .number(0)])
            #expect(submitted.ok, "\(submitted.error ?? "")")
            let jobID = try #require(submitted.result?["jobId"]?.stringValue)
            #expect(jobID.hasPrefix("sing-"))
            var last: ControlResponse?
            let finished = await SingWireFixture.waitUntil(60) {
                last = await wire("sing.jobStatus", ["jobId": .string(jobID)])
                let state = last?.result?["state"]?.stringValue
                return state == "done" || state == "failed" || state == "cancelled"
            }
            let status = try #require(last?.result)
            #expect(finished, "the job reads \(status["phase"]?.stringValue ?? "?"): \(status["stageText"]?.stringValue ?? "")")
            #expect(status["state"]?.stringValue == "done",
                    "\(status["error"]?["message"]?.stringValue ?? "") \(status["error"]?["detail"]?.stringValue ?? "")")
            #expect(status["renderedUnits"]?.doubleValue == 2)
            #expect(status["result"]?["wordCheck"]?["verdict"]?.stringValue == "clear")
            let trackID = try #require(status["result"]?["trackId"]?.stringValue.flatMap(UUID.init(uuidString:)))
            #expect(await MainActor.run { store.tracks.contains { $0.id == trackID } })

            let health = await wire("sing.sidecarStatus")
            #expect(health.result?["state"]?.stringValue == "ready", "\(health.error ?? "")")
            #expect(health.result?["health"]?["commit"]?.stringValue == "stub")

            #expect(try await MainActor.run { try store.undo() } == "Land Sung Vocal")
            #expect(try await MainActor.run { try store.undo() } == "Set Lyrics")
            #expect(await MainActor.run { store.tracks } == tracksBefore, "two undos restore the song exactly")

            let stopped = await wire("sing.sidecarStop")
            #expect(stopped.ok, "\(stopped.error ?? "")")
            #expect(stopped.result?["stopped"]?.boolValue == true, "\(stopped.result?["evidence"] ?? .null)")
            #expect(stopped.result?["evidence"]?["portFree"]?.boolValue == true)
            #expect(stopped.result?["evidence"]?["probeUnreachable"]?.boolValue == true)
            #expect(stopped.result?["evidence"]?["treePidsAliveAfter"]?.arrayValue?.isEmpty == true)
        } catch {
            _ = try? await manager.stop()
            throw error
        }
        _ = try? await manager.stop()
    }
}

/// SE1's sine pitch tracker (SingFixture.frames), copied: the stub sings a sine at every planned pitch, so the note
/// check and gate L2 read real audio.
enum SingWireStubPitch {
    static func frames(at url: URL) throws -> [ClipPitchFrame] {
        let audio = try SingWAV.read(url)
        return frames(samples: audio.mono, sampleRate: audio.sampleRate)
    }

    static func frames(samples: [Float], sampleRate: Int) -> [ClipPitchFrame] {
        let rate = Double(sampleRate)
        let hop = max(1, Int(0.01 * rate))
        let window = max(2, Int(0.04 * rate))
        var frames: [ClipPitchFrame] = []
        var start = 0
        while start + window <= samples.count {
            let time = Double(start + window / 2) / rate
            var energy = 0.0
            for i in start..<(start + window) { energy += Double(samples[i]) * Double(samples[i]) }
            let rms = (energy / Double(window)).squareRoot()
            var crossings: [Double] = []
            if rms.isFinite, rms >= 1e-4 {
                for i in (start + 1)..<(start + window) {
                    let a = Double(samples[i - 1]), b = Double(samples[i])
                    if a < 0, b >= 0 { crossings.append(Double(i - 1) + (-a) / (b - a)) }
                }
            }
            if crossings.count >= 3 {
                let gaps = zip(crossings.dropFirst(), crossings).map { $0 - $1 }
                let mean = gaps.reduce(0, +) / Double(gaps.count)
                let spread = (gaps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(gaps.count)).squareRoot()
                let confidence = max(0, min(1, 1 - 5 * spread / mean))
                let hz = rate / mean
                if confidence >= 0.9, hz > 40, hz < 2_000 {
                    frames.append(ClipPitchFrame(timeSeconds: time, frequencyHz: hz, confidence: confidence,
                                                 levelDbfs: 20 * log10(rms), absence: nil))
                } else {
                    frames.append(ClipPitchFrame(timeSeconds: time, frequencyHz: nil, confidence: confidence,
                                                 levelDbfs: 20 * log10(rms), absence: .belowConfidence))
                }
            } else {
                frames.append(ClipPitchFrame(timeSeconds: time, frequencyHz: nil, confidence: 0,
                                             levelDbfs: nil, absence: .belowLevel))
            }
            start += hop
        }
        return frames
    }
}
