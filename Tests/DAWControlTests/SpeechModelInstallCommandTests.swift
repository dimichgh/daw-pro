import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWControl

// Control-protocol coverage for m23-n3b `ai.installSpeechModel` /
// `ai.speechModelInstallStatus` — wire registration, param validation, the
// start-then-poll shape, and the in-flight refusal AT THE WIRE (the
// coordinator-level concurrency proof lives in
// AIServicesTests/WhisperModelInstallCoordinatorTests.swift; this suite only
// proves the router forwards to it correctly end to end). No real install
// ever runs — every test injects a `WhisperModelInstallCoordinator`
// constructed with a scripted, gated fake `InstallFunction`.
@MainActor
@Suite("ai.installSpeechModel / ai.speechModelInstallStatus — control protocol (m23-n3b)")
struct SpeechModelInstallCommandTests {

    // MARK: - Fixtures

    private func fixtureDescriptor(variant: String) -> WhisperModelDescriptor {
        let base = URL(fileURLWithPath: "/private/tmp/speech-model-command-fixture-\(UUID().uuidString)")
        return WhisperModelDescriptor(
            variantDirectoryName: variant,
            displayName: variant,
            modelFolder: base.appendingPathComponent(variant),
            tokenizerFolder: base.appendingPathComponent(variant).appendingPathComponent("tokenizer"),
            modelSizeBytes: 1024,
            tokenizerSizeBytes: 128,
            hasContextPrefill: false)
    }

    /// A gated fake install function — same shape as
    /// `AIServicesTests/WhisperModelInstallCoordinatorTests.swift`'s
    /// `InstallProbe`, reimplemented here rather than shared across test
    /// targets (AIServicesTests and DAWControlTests do not see each other's
    /// `private`/internal test types).
    private actor FakeInstallGate {
        enum GateError: Error { case unconfigured }

        private var released = false
        private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
        private var scriptedProgress: [WhisperModelInstallProgress] = []
        private var outcome: Result<WhisperModelDescriptor, Error> = .failure(GateError.unconfigured)

        func configure(
            scriptedProgress: [WhisperModelInstallProgress] = [],
            outcome: Result<WhisperModelDescriptor, Error>
        ) {
            self.scriptedProgress = scriptedProgress
            self.outcome = outcome
            self.released = false
        }

        func release() {
            released = true
            let pending = releaseContinuations
            releaseContinuations.removeAll()
            for continuation in pending { continuation.resume() }
        }

        private func waitForRelease() async {
            if released { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                releaseContinuations.append(continuation)
            }
        }

        func function(
            variant: String, overwrite: Bool, repo: String, token: String?,
            progress: @escaping @Sendable (WhisperModelInstallProgress) -> Void
        ) async throws -> WhisperModelDescriptor {
            for tick in scriptedProgress { progress(tick) }
            await waitForRelease()
            switch outcome {
            case .success(let descriptor): return descriptor
            case .failure(let error): throw error
            }
        }

        nonisolated var asInstallFunction: WhisperModelInstallCoordinator.InstallFunction {
            { [self] variant, overwrite, repo, token, progress in
                try await self.function(
                    variant: variant, overwrite: overwrite, repo: repo, token: token, progress: progress)
            }
        }
    }

    private func makeRouter(
        coordinator: WhisperModelInstallCoordinator = WhisperModelInstallCoordinator()
    ) -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store, installCoordinator: coordinator), store)
    }

    /// Polls `ai.speechModelInstallStatus` through the wire until `matches`
    /// holds or a bounded timeout elapses (mirrors the AIServicesTests
    /// polling idiom — the coordinator's background `Task` runs off-actor,
    /// so a status right after `start` can legitimately still be mid-flight).
    private func pollStatus(
        _ router: CommandRouter,
        until matches: (ControlResponse) -> Bool,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async -> ControlResponse {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        var response = await router.handle(ControlRequest(id: "poll", command: "ai.speechModelInstallStatus"))
        while !matches(response), DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
            response = await router.handle(ControlRequest(id: "poll", command: "ai.speechModelInstallStatus"))
        }
        return response
    }

    // MARK: - Wire law

    @Test("both verbs are registered, additive, adjacent and in order; wire count 159 -> 161 -> 162 at m23-r4 (fx.spectrum landed after)")
    func commandsRegistered() {
        let all = CommandRouter.allCommands
        #expect(all.count == 171)   // 159 -> 161 at m23-n3b -> 162 at m23-r4 -> 163 at m23-o1 -> 165 at m23-w -> 166 at m23-af -> 168 at m20-j -> 169 at m23-br-1 -> 171 at m23-aj-2
        // m23-r4's fx.spectrum is additive-at-the-END (its own law), which
        // moved these two off the absolute tail — pin their ADJACENCY and
        // ORDER instead of an absolute suffix, so a later additive command
        // never has to touch this test again.
        if let installIndex = all.firstIndex(of: "ai.installSpeechModel"),
           let statusIndex = all.firstIndex(of: "ai.speechModelInstallStatus") {
            #expect(statusIndex == installIndex + 1,
                    "ai.speechModelInstallStatus must immediately follow ai.installSpeechModel")
        } else {
            Issue.record("ai.installSpeechModel or ai.speechModelInstallStatus missing from allCommands")
        }
        // Additive: the just-landed clip.transcribe (m23-n2b) precedes both.
        if let transcribeIndex = all.firstIndex(of: "clip.transcribe"),
           let installIndex = all.firstIndex(of: "ai.installSpeechModel") {
            #expect(transcribeIndex < installIndex)
        } else {
            Issue.record("clip.transcribe or ai.installSpeechModel missing from allCommands")
        }
    }

    // MARK: - ai.installSpeechModel

    @Test("starts and returns an .installing snapshot immediately, naming the requested variant")
    func startsAndReturnsImmediately() async throws {
        let gate = FakeInstallGate()
        await gate.configure(outcome: .success(fixtureDescriptor(variant: "openai_whisper-tiny.en")))
        let coordinator = WhisperModelInstallCoordinator(installFunction: gate.asInstallFunction)
        let (router, _) = makeRouter(coordinator: coordinator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.installSpeechModel", params: ["variant": .string("tiny.en")]))
        #expect(response.ok)
        #expect(response.result?["state"]?.stringValue == "installing")
        #expect(response.result?["variantDirectoryNameRequested"]?.stringValue == "tiny.en")
        #expect(response.result?["descriptor"] == nil)

        await gate.release()
    }

    @Test("unknown params are rejected with the teaching key list")
    func rejectsUnknownKeys() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.installSpeechModel",
            params: ["variant": .string("tiny.en"), "token": .string("x")]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'token'") == true)
        #expect(response.error?.contains("valid keys are 'overwrite', 'variant'") == true)
    }

    @Test("missing variant is field-named")
    func missingVariant() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(id: "1", command: "ai.installSpeechModel"))
        #expect(!response.ok)
        #expect(response.error?.contains("variant") == true)
    }

    @Test("a second call while one is running is refused at the wire, naming both variants")
    func refusesSecondCallWhileInstalling() async throws {
        let gate = FakeInstallGate()
        await gate.configure(outcome: .success(fixtureDescriptor(variant: "a")))
        let coordinator = WhisperModelInstallCoordinator(installFunction: gate.asInstallFunction)
        let (router, _) = makeRouter(coordinator: coordinator)

        let first = await router.handle(ControlRequest(
            id: "1", command: "ai.installSpeechModel", params: ["variant": .string("a")]))
        #expect(first.ok)

        let second = await router.handle(ControlRequest(
            id: "2", command: "ai.installSpeechModel", params: ["variant": .string("b")]))
        #expect(!second.ok)
        #expect(second.error?.contains("Already installing \"a\"") == true)
        #expect(second.error?.contains("\"b\"") == true)

        await gate.release()
    }

    // MARK: - ai.speechModelInstallStatus

    @Test("status is idle before anything starts, and rejects unknown params")
    func statusIdleAndRejectsUnknownKeys() async throws {
        let (router, _) = makeRouter()

        let idle = await router.handle(ControlRequest(id: "1", command: "ai.speechModelInstallStatus"))
        #expect(idle.ok)
        #expect(idle.result?["state"]?.stringValue == "idle")

        let rejected = await router.handle(ControlRequest(
            id: "2", command: "ai.speechModelInstallStatus", params: ["variant": .string("x")]))
        #expect(!rejected.ok)
        #expect(rejected.error?.contains("unknown parameter 'variant'") == true)
    }

    @Test("status reflects a progress tick while installing, then the terminal descriptor")
    func statusReflectsProgressThenTerminal() async throws {
        let gate = FakeInstallGate()
        let tick = WhisperModelInstallProgress(
            phase: .downloadingModel, variantDirectoryName: "openai_whisper-tiny.en",
            phaseFraction: 0.5, completedUnitCount: 5, totalUnitCount: 10)
        await gate.configure(
            scriptedProgress: [tick],
            outcome: .success(fixtureDescriptor(variant: "openai_whisper-tiny.en")))
        let coordinator = WhisperModelInstallCoordinator(installFunction: gate.asInstallFunction)
        let (router, _) = makeRouter(coordinator: coordinator)

        let start = await router.handle(ControlRequest(
            id: "1", command: "ai.installSpeechModel", params: ["variant": .string("tiny.en")]))
        #expect(start.ok)

        let mid = await pollStatus(router) { $0.result?["progress"] != nil }
        #expect(mid.result?["state"]?.stringValue == "installing")
        #expect(mid.result?["progress"]?["phaseFraction"]?.doubleValue == 0.5)
        #expect(mid.result?["progress"]?["phase"]?.stringValue == "downloadingModel")

        await gate.release()
        let final = await pollStatus(router) { $0.result?["state"]?.stringValue != "installing" }
        #expect(final.result?["state"]?.stringValue == "succeeded")
        #expect(final.result?["descriptor"]?["variantDirectoryName"]?.stringValue
            == "openai_whisper-tiny.en")
    }

    @Test("a failed install surfaces its readable message via status, never as a thrown error from start")
    func statusReflectsFailure() async throws {
        let gate = FakeInstallGate()
        await gate.configure(outcome: .failure(WhisperModelInstallError.unrecognisedVariant(
            requested: "openai_whisper-enormous", known: ["tiny", "base"])))
        let coordinator = WhisperModelInstallCoordinator(installFunction: gate.asInstallFunction)
        let (router, _) = makeRouter(coordinator: coordinator)

        let start = await router.handle(ControlRequest(
            id: "1", command: "ai.installSpeechModel",
            params: ["variant": .string("openai_whisper-enormous")]))
        #expect(start.ok)   // accepted — the fast failure surfaces via status, not here
        #expect(start.result?["state"]?.stringValue == "installing")

        await gate.release()
        let final = await pollStatus(router) { $0.result?["state"]?.stringValue != "installing" }
        #expect(final.result?["state"]?.stringValue == "failed")
        #expect(final.result?["errorMessage"]?.stringValue?.contains("openai_whisper-enormous") == true)
    }
}
