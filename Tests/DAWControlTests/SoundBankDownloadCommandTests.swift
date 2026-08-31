import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWControl

/// Control-protocol coverage for m34-c's four one-click SoundFont download
/// verbs: wire registration, param validation, the start-then-poll-then-cancel
/// shape, and the response encoding.
///
/// No real download ever runs — every test that starts one injects a
/// `SoundBankDownloadCoordinator` built with a gated fake `InstallFunction`.
/// The installer's own gates (size, checksum, the `namesParsed` sentinel) are
/// proven in `AIServicesTests/SoundBankInstallerTests`; this suite only proves
/// the router forwards to the coordinator correctly.
@MainActor
@Suite("instrument.*SoundBank* download — control protocol (m34-c)")
struct SoundBankDownloadCommandTests {

    // MARK: - Fixtures

    /// A gated fake install function, the `SpeechModelInstallCommandTests`
    /// idiom (reimplemented rather than shared — AIServicesTests and
    /// DAWControlTests do not see each other's test types).
    private actor FakeInstallGate {
        enum GateError: Error { case unconfigured }

        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var scripted: [SoundBankDownloadProgress] = []
        private var outcome: Result<SoundBankInfo, Error> = .failure(GateError.unconfigured)

        func configure(scripted: [SoundBankDownloadProgress] = [],
                       outcome: Result<SoundBankInfo, Error>) {
            self.scripted = scripted
            self.outcome = outcome
            self.released = false
        }

        func release() {
            released = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }

        private func waitForRelease() async {
            if released { return }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiters.append(c)
            }
        }

        func function(bank: DownloadableSoundBank,
                      progress: @escaping @Sendable (SoundBankDownloadProgress) -> Void)
            async throws -> SoundBankInfo {
            for tick in scripted { progress(tick) }
            await waitForRelease()
            switch outcome {
            case .success(let info): return info
            case .failure(let error): throw error
            }
        }

        nonisolated var asInstallFunction: SoundBankDownloadCoordinator.InstallFunction {
            { [self] bank, progress in
                try await self.function(bank: bank, progress: progress)
            }
        }
    }

    private static func installedInfo() -> SoundBankInfo {
        let path = "/private/tmp/soundbank-command-fixture/MuseScore_General.sf2"
        return SoundBankInfo(source: .file(path: path), name: "MuseScore_General",
                             path: path, format: "sf2", builtin: false,
                             sizeBytes: 215_614_036)
    }

    private func makeRouter(
        coordinator: SoundBankDownloadCoordinator = SoundBankDownloadCoordinator()
    ) -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        return (CommandRouter(store: store, soundBankDownloads: coordinator), store)
    }

    /// Polls the status verb until `matches` holds or a bounded timeout
    /// elapses — the coordinator's job runs off-actor, so a status read right
    /// after `start` can legitimately still be mid-flight.
    private func pollStatus(_ router: CommandRouter,
                            until matches: (ControlResponse) -> Bool,
                            timeoutNanoseconds: UInt64 = 3_000_000_000) async -> ControlResponse {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        var response = await router.handle(ControlRequest(
            id: "poll", command: "instrument.soundBankDownloadStatus"))
        while !matches(response), DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
            response = await router.handle(ControlRequest(
                id: "poll", command: "instrument.soundBankDownloadStatus"))
        }
        return response
    }

    // MARK: - Wire law

    @Test("all four verbs are registered, adjacent, in order, and additive at the tail")
    func commandsRegistered() {
        let all = CommandRouter.allCommands
        let expected = ["instrument.listDownloadableSoundBanks",
                        "instrument.downloadSoundBank",
                        "instrument.soundBankDownloadStatus",
                        "instrument.cancelSoundBankDownload"]
        for verb in expected {
            #expect(all.contains(verb), "\(verb) missing from allCommands")
        }
        // Negative control: a plausible name that must NOT be there, so the
        // membership checks above are evidence rather than a tautology.
        #expect(!all.contains("instrument.downloadSoundFont"))
        // Adjacent and in order.
        let indices = expected.compactMap { all.firstIndex(of: $0) }
        #expect(indices.count == 4)
        #expect(indices == Array(indices.sorted()))
        if let first = indices.first {
            #expect(indices == Array(first..<(first + 4)))
        }
        // ⚠️ NOT at the tail, and that is deliberate — see the block comment
        // at their registration. They sit immediately after
        // instrument.importSoundBank, their nearest sibling, so every
        // dropLast(N) window elsewhere in the suite stays true. A tail
        // placement was tried and reddened 14 tests.
        #expect(Array(all.suffix(4)) != expected, "these must NOT be at the tail")
        if let importIndex = all.firstIndex(of: "instrument.importSoundBank"),
           let firstNew = indices.first {
            #expect(firstNew == importIndex + 1,
                    "the download verbs follow instrument.importSoundBank directly")
        } else {
            Issue.record("instrument.importSoundBank disappeared")
        }
        // The pre-existing sound-bank verbs are untouched and still come first.
        if let listIndex = all.firstIndex(of: "instrument.listSoundBanks"),
           let downloadIndex = all.firstIndex(of: "instrument.downloadSoundBank") {
            #expect(listIndex < downloadIndex)
        } else {
            Issue.record("instrument.listSoundBanks disappeared")
        }
    }

    // MARK: - instrument.listDownloadableSoundBanks

    @Test("the catalogue lists MuseScore General with its licence, size and integrity pin")
    func listsCatalogue() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.listDownloadableSoundBanks"))
        #expect(response.ok)
        let banks = response.result?["banks"]?.arrayValue ?? []
        #expect(banks.count == 1)
        let bank = banks.first
        #expect(bank?["id"]?.stringValue == "musescore-general")
        #expect(bank?["name"]?.stringValue == "MuseScore General")
        #expect(bank?["sizeBytes"]?.doubleValue == 215_614_036)
        // Derived from expectedBytes by the ONE size arithmetic, not a literal.
        #expect(bank?["sizeDescription"]?.stringValue == "216 MB")
        #expect(bank?["licence"]?.stringValue == "MIT")
        #expect(bank?["attribution"]?.stringValue?.contains("Frank Wen") == true)
        #expect(bank?["sha256"]?.stringValue
            == "ee51d2c4b1525e70f19a45909c4fd7a2e26d91d115fa89dbf5a6bc413d8b9bf3")
        // ⚠️ UPDATED 2026-08-30: the primary moved to our own release asset when
        // the user chose to mirror the bank; upstream stays wired as a fallback
        // and is pinned in `SoundBankInstallerTests`. The echo carries the
        // PRIMARY only — the fallback is resilience, not something an agent
        // chooses between.
        #expect(bank?["url"]?.stringValue?
            .hasPrefix("https://github.com/dimichgh/daw-pro/releases/") == true)
        #expect(bank?["url"]?.stringValue?.hasSuffix(".sf2") == true)
        // `installed` is always present; `installedPath` only when it is.
        #expect(bank?["installed"]?.boolValue != nil)
        if bank?["installed"]?.boolValue == false {
            #expect(bank?["installedPath"] == nil,
                    "an absent path must be OMITTED, not encoded as null")
        }
    }

    @Test("the catalogue verb takes no parameters")
    func catalogueRejectsParams() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.listDownloadableSoundBanks",
            params: ["id": .string("musescore-general")]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'id'") == true)
    }

    // MARK: - instrument.downloadSoundBank

    @Test("starts and returns a downloading snapshot immediately, naming the bank")
    func startsAndReturnsImmediately() async throws {
        let gate = FakeInstallGate()
        await gate.configure(outcome: .success(Self.installedInfo()))
        let (router, _) = makeRouter(
            coordinator: SoundBankDownloadCoordinator(installFunction: gate.asInstallFunction))

        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.downloadSoundBank",
            params: ["id": .string("musescore-general")]))
        #expect(response.ok)
        #expect(response.result?["state"]?.stringValue == "downloading")
        #expect(response.result?["bankID"]?.stringValue == "musescore-general")
        #expect(response.result?["bankName"]?.stringValue == "MuseScore General")
        #expect(response.result?["cancelRequested"]?.boolValue == false)
        // Accepted is NOT installed: no bank on a non-terminal status.
        #expect(response.result?["bank"] == nil)

        await gate.release()
        _ = await pollStatus(router) { $0.result?["state"]?.stringValue == "succeeded" }
    }

    @Test("an unknown catalogue id is refused in the same round trip, listing what exists")
    func unknownIDRefused() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.downloadSoundBank",
            params: ["id": .string("not-a-bank")]))
        #expect(!response.ok)
        #expect(response.error?.contains("not-a-bank") == true)
        #expect(response.error?.contains("musescore-general") == true)
    }

    @Test("id is required, and unknown params are rejected with the teaching key list")
    func rejectsBadParams() async throws {
        let (router, _) = makeRouter()
        let missing = await router.handle(ControlRequest(
            id: "1", command: "instrument.downloadSoundBank"))
        #expect(!missing.ok)

        let unknown = await router.handle(ControlRequest(
            id: "2", command: "instrument.downloadSoundBank",
            params: ["id": .string("musescore-general"), "overwrite": .bool(true)]))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("unknown parameter 'overwrite'") == true)
        #expect(unknown.error?.contains("valid keys are 'id'") == true)
    }

    @Test("a second download while one runs is refused, naming the one in flight")
    func secondDownloadRefused() async throws {
        let gate = FakeInstallGate()
        await gate.configure(outcome: .success(Self.installedInfo()))
        let (router, _) = makeRouter(
            coordinator: SoundBankDownloadCoordinator(installFunction: gate.asInstallFunction))

        let first = await router.handle(ControlRequest(
            id: "1", command: "instrument.downloadSoundBank",
            params: ["id": .string("musescore-general")]))
        #expect(first.ok)
        let second = await router.handle(ControlRequest(
            id: "2", command: "instrument.downloadSoundBank",
            params: ["id": .string("musescore-general")]))
        #expect(!second.ok)
        #expect(second.error?.contains("Only one sound-bank download runs at a time") == true)

        await gate.release()
        _ = await pollStatus(router) { $0.result?["state"]?.stringValue == "succeeded" }
    }

    // MARK: - instrument.soundBankDownloadStatus

    @Test("status is idle before anything runs, then carries progress, then the installed bank")
    func statusLifecycle() async throws {
        let gate = FakeInstallGate()
        await gate.configure(
            scripted: [SoundBankDownloadProgress(
                phase: .downloading, bankID: "musescore-general", phaseFraction: 0.5,
                completedBytes: 107_807_018, totalBytes: 215_614_036)],
            outcome: .success(Self.installedInfo()))
        let (router, _) = makeRouter(
            coordinator: SoundBankDownloadCoordinator(installFunction: gate.asInstallFunction))

        let idle = await router.handle(ControlRequest(
            id: "0", command: "instrument.soundBankDownloadStatus"))
        #expect(idle.ok)
        #expect(idle.result?["state"]?.stringValue == "idle")

        _ = await router.handle(ControlRequest(
            id: "1", command: "instrument.downloadSoundBank",
            params: ["id": .string("musescore-general")]))
        let ticking = await pollStatus(router) { $0.result?["progress"] != nil }
        let progress = ticking.result?["progress"]
        #expect(progress?["phase"]?.stringValue == "downloading")
        #expect(progress?["phaseFraction"]?.doubleValue == 0.5)
        #expect(progress?["completedBytes"]?.doubleValue == 107_807_018)
        #expect(progress?["totalBytes"]?.doubleValue == 215_614_036)

        await gate.release()
        let done = await pollStatus(router) { $0.result?["state"]?.stringValue == "succeeded" }
        #expect(done.result?["bank"]?["format"]?.stringValue == "sf2")
        #expect(done.result?["bank"]?["source"]?.stringValue?.hasSuffix(".sf2") == true)
        #expect(done.result?["errorMessage"] == nil)
    }

    @Test("a failed install surfaces the installer's own teaching sentence, never a raw dump")
    func failureSurfacesTeachingMessage() async throws {
        let gate = FakeInstallGate()
        await gate.configure(outcome: .failure(SoundBankInstallError.installedButUnreadable(
            name: "MuseScore General", path: "/tmp/MuseScore_General.sf2")))
        let (router, _) = makeRouter(
            coordinator: SoundBankDownloadCoordinator(installFunction: gate.asInstallFunction))

        _ = await router.handle(ControlRequest(
            id: "1", command: "instrument.downloadSoundBank",
            params: ["id": .string("musescore-general")]))
        await gate.release()
        let failed = await pollStatus(router) { $0.result?["state"]?.stringValue == "failed" }
        let message = failed.result?["errorMessage"]?.stringValue ?? ""
        #expect(message.contains("couldn't read any instrument names"))
        #expect(message.contains("rather than left there looking usable"))
        #expect(failed.result?["bank"] == nil, "a failed download must never report a bank")
    }

    // MARK: - instrument.cancelSoundBankDownload

    @Test("cancel reports cancelRequested while still downloading, then reaches cancelled")
    func cancelLifecycle() async throws {
        // A cancellation-aware fake: it waits for the task to be cancelled,
        // then throws exactly what the real installer throws.
        let coordinator = SoundBankDownloadCoordinator { bank, _ in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 3_000_000) }
            throw SoundBankInstallError.cancelled(name: bank.name)
        }
        let (router, _) = makeRouter(coordinator: coordinator)

        _ = await router.handle(ControlRequest(
            id: "1", command: "instrument.downloadSoundBank",
            params: ["id": .string("musescore-general")]))
        let cancelling = await router.handle(ControlRequest(
            id: "2", command: "instrument.cancelSoundBankDownload"))
        #expect(cancelling.ok)
        // ⚠️ Deliberately STILL downloading: the partial file is not gone
        // until the job unwinds, and a status that raced the filesystem would
        // be exactly the "reports success early" defect this item is about.
        #expect(cancelling.result?["state"]?.stringValue == "downloading")
        #expect(cancelling.result?["cancelRequested"]?.boolValue == true)

        let cancelled = await pollStatus(router) {
            $0.result?["state"]?.stringValue == "cancelled"
        }
        #expect(cancelled.result?["state"]?.stringValue == "cancelled")
        #expect(cancelled.result?["errorMessage"]?.stringValue?.contains("cancelled") == true)
        #expect(cancelled.result?["bank"] == nil)
    }

    @Test("cancelling with nothing running is refused rather than a silent success")
    func cancelWithNothingRunning() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.cancelSoundBankDownload"))
        #expect(!response.ok)
        #expect(response.error?.contains("nothing to cancel") == true)
    }

    @Test("cancel takes no parameters")
    func cancelRejectsParams() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.cancelSoundBankDownload",
            params: ["id": .string("musescore-general")]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'id'") == true)
    }
}
