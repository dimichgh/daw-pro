import Foundation
import Testing
@testable import AIServices
@testable import DAWCore

/// p2-sing-e part 2: the AIServices pieces behind the singing verbs, tested alone: the progress-card mapping, the
/// consent broker, the engine's files (pins, the uninstall guard) and the speech-model fallback. Nonisolated; the
/// MainActor broker is driven through `MainActor.run` / awaited calls.
@Suite("SingWire — the presence mapping, the consent broker and the engine's files (p2-sing-e)")
struct SingWireServicesTests {

    static func status(_ phase: SingJobPhase, error: SingJobFailure? = nil) -> SingJobStatus {
        SingJobStatus(
            jobID: "sing-x", clipID: UUID(), phase: phase, stageText: "stage", unitIndex: nil, unitCount: 2,
            progress: 0.5, etaSeconds: nil, waitingFor: nil, cancelRequested: false, seed: 1, retriedUnits: [],
            cachedUnits: 0, renderedUnits: 0, yields: 0, engineRestarts: 0, warnings: [], notices: [], result: nil,
            gates: nil, error: error, keptTakePath: nil, fromAgent: true, submittedAt: Date(), finishedAt: nil)
    }

    @Test("the card's view of a sing job: never queued, failed in words, done with an audio marker; lookup never throws")
    func presenceMapping() async {
        for phase in [SingJobPhase.queued, .waitingForModel, .startingEngine, .preparingVoice, .singing, .finishing,
                      .landed, .checking] {
            let mapped = SingPresenceBridge.generationStatus(Self.status(phase))
            #expect(mapped.state == .running, "\(phase) must not read queued: the card would paint ACE's boot on it")
            #expect(mapped.stage == "stage" && mapped.progress == 0.5)
        }
        let done = SingPresenceBridge.generationStatus(Self.status(.done))
        #expect(done.state == .succeeded && done.audioPath?.isEmpty == false)
        let failed = SingPresenceBridge.generationStatus(
            Self.status(.failed, error: SingJobFailure(code: "x", message: "The singing engine stopped unexpectedly.")))
        #expect(failed.state == .failed && failed.statusText == "The singing engine stopped unexpectedly.")
        let cancelled = SingPresenceBridge.generationStatus(Self.status(.cancelled))
        #expect(cancelled.state == .failed && cancelled.statusText == "stage")

        let unknown = await SingPresenceBridge.lookup(jobID: "sing-gone") { id in throw SingJobError.jobNotFound(id) }
        #expect(unknown.state == .failed)
        #expect(unknown.statusText == "No sing job with id \"sing-gone\" — sing.jobStatus with no id lists the recent ones.")
        #expect(SingPresenceBridge.isSingJob("sing-1") && !SingPresenceBridge.isSingJob("ace-1"))
    }

    @Test("the broker: a request waits, a repeat is the same request, yes performs, no does not, and the flag is the environment's alone")
    func consentBroker() async throws {
        let performed = SingFixtureLog()
        let broker = await MainActor.run { () -> SingConsentBroker in
            let broker = SingConsentBroker(autoConsent: false)
            broker.performer = { action in performed.append(action.rawValue) }
            return broker
        }
        let first = try await broker.request(.installEngine, fromAgent: true)
        guard case .awaitingUserConsent(let request) = first else {
            Issue.record("expected a waiting request, got \(first)")
            return
        }
        #expect(request.message == "An AI agent wants to install the singing engine: about 7 GB, one time.")
        #expect(try await broker.request(.installEngine, fromAgent: true) == .awaitingUserConsent(request))
        #expect(performed.calls.isEmpty)
        try await broker.approve(id: request.id)
        #expect(performed.calls == ["installEngine"])
        await #expect(throws: SingConsentError.noSuchRequest(request.id)) { try await broker.approve(id: request.id) }

        let uninstall = try await broker.request(.uninstallEngine, fromAgent: false)
        guard case .awaitingUserConsent(let removal) = uninstall else {
            Issue.record("expected a waiting request")
            return
        }
        try await MainActor.run { try broker.decline(id: removal.id) }
        #expect(performed.calls == ["installEngine"])

        #expect(SingConsentBroker.autoConsentFromEnvironment(["DAWPRO_SING_TEST_AUTO_CONSENT": "1"]))
        #expect(!SingConsentBroker.autoConsentFromEnvironment(["DAWPRO_SING_TEST_AUTO_CONSENT": "true"]))
        #expect(!SingConsentBroker.autoConsentFromEnvironment([:]))
        let unwired = await MainActor.run { SingConsentBroker(autoConsent: true) }
        await #expect(throws: SingConsentError.notConnected) { _ = try await unwired.request(.installEngine, fromAgent: true) }
    }

    @Test("the engine's files: pins.env is read line by line; the uninstall deletes only a folder named SingingEngine")
    func engineFiles() throws {
        let root = try SingFixture.tempDir("engine-files")
        defer { try? FileManager.default.removeItem(at: root) }
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data("# comment\nMIN_FREE_KB=100\nMODEL_FILE=\"weights.pt\"\n".utf8)
            .write(to: scripts.appendingPathComponent("pins.env"))
        let runtime = root.appendingPathComponent("SingingEngine", isDirectory: true)
        let files = SingEngineFiles(runtimeDir: runtime, scriptsDir: scripts)
        #expect(files.minFreeBytes() == 102_400)
        #expect(files.weightsURL?.lastPathComponent == "weights.pt")
        #expect(SingEngineFiles(runtimeDir: runtime, scriptsDir: nil).minFreeBytes() == 12_582_912 * 1024)
        #expect(files.runtimeFacts() == nil && !files.isPresent && files.preflightProblems().isEmpty)

        try FileManager.default.createDirectory(at: runtime.appendingPathComponent("weights"),
                                                withIntermediateDirectories: true)
        try Data(count: 4096).write(to: runtime.appendingPathComponent("weights/weights.pt"))
        #expect(files.sizeOnDisk() >= 4096)
        #expect(try files.removeRuntime() >= 4096)
        #expect(!FileManager.default.fileExists(atPath: runtime.path))

        let other = root.appendingPathComponent("NotTheEngine", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(throws: SingEngineFiles.RemoveError.refusedPath(other.standardizedFileURL.path)) {
            try SingEngineFiles(runtimeDir: other, scriptsDir: nil).removeRuntime()
        }
        #expect(FileManager.default.fileExists(atPath: other.path), "never deleted")
    }

    @Test("the word check's transcribe returns nil, never throws, when no speech model is installed")
    func transcribeWithoutAModelIsNil() async throws {
        let root = try SingFixture.tempDir("no-speech-model")
        defer { try? FileManager.default.removeItem(at: root) }
        let transcriber = WhisperTranscriber(catalog: WhisperModelCatalog(searchRoot: root))
        let heard = try await SingSpeech.transcribe(transcriber, root.appendingPathComponent("any.wav"))
        #expect(heard == nil)
        #expect(SingVoiceWordCheck.check(heard: nil).state == "skipped")
        let checked = SingVoiceWordCheck.check(heard: "row row row your boat gently down the stream")
        #expect(checked.state == "checked" && checked.wer == 0 && checked.verdict == "clear")
    }
}

/// A Sendable call log for the closures above.
final class SingFixtureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    var calls: [String] { lock.withLock { entries } }
    func append(_ call: String) { lock.withLock { entries.append(call) } }
}
