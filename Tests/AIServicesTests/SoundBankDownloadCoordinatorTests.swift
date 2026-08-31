import Foundation
import Testing
import DAWCore
@testable import AIServices

/// Single-flight, poll and cancel for sound-bank downloads (m34-c). No network
/// and no filesystem: every test injects an `InstallFunction`, which is the
/// same seam `WhisperModelInstallCoordinatorTests` uses and for the same
/// reason — the real 206 MB fetch is a one-off, not something a suite pays for.
@Suite("Sound-bank download coordinator (m34-c)")
struct SoundBankDownloadCoordinatorTests {

    private static let bank = DownloadableSoundBankCatalog.museScoreGeneral

    private static func info(_ path: String = "/tmp/MuseScore_General.sf2") -> SoundBankInfo {
        SoundBankInfo(source: .file(path: path), name: "MuseScore_General",
                      path: path, format: "sf2", builtin: false, sizeBytes: 215_614_036)
    }

    // MARK: Start

    @Test("a fresh coordinator is idle, and start reports downloading immediately")
    func startsDownloading() async throws {
        let gate = Gate()
        let coordinator = SoundBankDownloadCoordinator { _, _ in
            await gate.wait()
            return Self.info()
        }
        #expect(await coordinator.status().state == .idle)
        let started = try await coordinator.start(bankID: "musescore-general")
        #expect(started.state == .downloading)
        #expect(started.bankID == "musescore-general")
        #expect(started.bankName == "MuseScore General")
        #expect(started.cancelRequested == false)
        await gate.open()
        await Self.settle(coordinator)
        #expect(await coordinator.status().state == .succeeded)
        #expect(await coordinator.status().bank?.format == "sf2")
    }

    @Test("an id that is not in the catalog is refused in the same round trip")
    func unknownIDRefused() async throws {
        let coordinator = SoundBankDownloadCoordinator { _, _ in Self.info() }
        await #expect(throws: SoundBankInstallError.unknownBank(
            requested: "not-a-bank",
            known: DownloadableSoundBankCatalog.all.map(\.id))) {
            try await coordinator.start(bankID: "not-a-bank")
        }
        // Nothing was started — the refusal is not a silent no-op.
        #expect(await coordinator.status().state == .idle)
    }

    @Test("only one download is ever in flight, and the installer runs once")
    func singleFlight() async throws {
        let gate = Gate()
        let calls = Counter()
        let coordinator = SoundBankDownloadCoordinator { _, _ in
            await calls.bump()
            await gate.wait()
            return Self.info()
        }
        try await coordinator.start(bank: Self.bank)
        await #expect(throws: SoundBankDownloadCoordinatorError.downloadAlreadyInFlight(
            requested: Self.bank.name, inFlight: Self.bank.name)) {
            try await coordinator.start(bank: Self.bank)
        }
        await gate.open()
        await Self.settle(coordinator)
        #expect(await calls.value() == 1)
        // Terminal now, so a second download IS allowed.
        try await coordinator.start(bank: Self.bank)
        await gate.open()
        await Self.settle(coordinator)
        #expect(await calls.value() == 2)
    }

    // MARK: Progress

    @Test("status carries the latest progress tick and clears it between downloads")
    func progressIsLatestWins() async throws {
        let gate = Gate()
        let coordinator = SoundBankDownloadCoordinator { bank, report in
            report(SoundBankDownloadProgress(
                phase: .downloading, bankID: bank.id, phaseFraction: 0.25,
                completedBytes: 50, totalBytes: 200))
            report(SoundBankDownloadProgress(
                phase: .downloading, bankID: bank.id, phaseFraction: 0.75,
                completedBytes: 150, totalBytes: 200))
            await gate.wait()
            return Self.info()
        }
        try await coordinator.start(bank: Self.bank)
        // Let the injected function reach its two report calls.
        try await Task.sleep(nanoseconds: 30_000_000)
        let mid = await coordinator.status()
        #expect(mid.state == .downloading)
        #expect(mid.progress?.phaseFraction == 0.75)
        #expect(mid.progress?.completedBytes == 150)
        await gate.open()
        await Self.settle(coordinator)

        // A SECOND download must not inherit the first one's fraction before
        // its own first tick lands (the m23-n3b lesson, restated here because
        // it is the same box).
        let silentGate = Gate()
        let silent = SoundBankDownloadCoordinator { _, _ in
            await silentGate.wait()
            return Self.info()
        }
        try await silent.start(bank: Self.bank)
        #expect(await silent.status().progress == nil)
        await silentGate.open()
        await Self.settle(silent)
    }

    @Test("a download that never ticks still reaches a terminal state")
    func silentDownloadStillTerminates() async throws {
        let coordinator = SoundBankDownloadCoordinator { _, _ in Self.info() }
        try await coordinator.start(bank: Self.bank)
        await Self.settle(coordinator)
        let final = await coordinator.status()
        #expect(final.state == .succeeded)
        #expect(final.progress == nil)
    }

    // MARK: Failure

    @Test("a failed install reports the installer's own sentence, not a Swift error dump")
    func failureCarriesTheTeachingMessage() async throws {
        let coordinator = SoundBankDownloadCoordinator { _, _ in
            throw SoundBankInstallError.sizeMismatch(
                expectedBytes: 215_614_036, actualBytes: 1_000_000)
        }
        try await coordinator.start(bank: Self.bank)
        await Self.settle(coordinator)
        let final = await coordinator.status()
        #expect(final.state == .failed)
        #expect(final.errorMessage?.contains("stopped early") == true)
        #expect(final.bank == nil)
    }

    // MARK: Cancel

    @Test("cancel requests a stop, and the job's own unwind reports cancelled")
    func cancelReachesCancelledState() async throws {
        let started = Gate()
        let coordinator = SoundBankDownloadCoordinator { bank, _ in
            await started.open()
            // A cancellation-aware transfer: sleeps until the task is
            // cancelled, then throws what SoundBankInstaller throws.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            throw SoundBankInstallError.cancelled(name: bank.name)
        }
        try await coordinator.start(bank: Self.bank)
        await started.wait()
        let cancelling = try await coordinator.cancel()
        // ⚠️ Cancellation is REQUESTED synchronously and OBSERVED by polling:
        // the state is still `.downloading` here, deliberately, because the
        // partial file is not gone until the job unwinds.
        #expect(cancelling.state == .downloading)
        #expect(cancelling.cancelRequested)
        await Self.settle(coordinator)
        let final = await coordinator.status()
        #expect(final.state == .cancelled)
        #expect(final.errorMessage?.contains("cancelled") == true)
        #expect(final.bank == nil)
    }

    @Test("cancelling with nothing running is refused rather than silently succeeding")
    func cancelWithNothingRunning() async throws {
        let coordinator = SoundBankDownloadCoordinator { _, _ in Self.info() }
        await #expect(throws: SoundBankDownloadCoordinatorError.nothingInFlight) {
            try await coordinator.cancel()
        }
    }

    // MARK: Offerings

    @Test("offerings report which catalog banks are already on disk")
    func offeringsReportInstalledState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soundbank-offerings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SoundBankLibrary(libraryDirectory: root, scanDirectories: [root])

        let before = SoundBankDownloadCoordinator.offerings(library: library)
        #expect(before.count == DownloadableSoundBankCatalog.all.count)
        #expect(before.first?.installedPath == nil)

        // A file with the catalog's own filename IS the installed bank.
        let landed = root.appendingPathComponent(Self.bank.fileName)
        try Data("RIFF....sfbk".utf8).write(to: landed)
        let after = SoundBankDownloadCoordinator.offerings(library: library)
        #expect(after.first?.installedPath == landed.standardizedFileURL.path)
    }
}

// MARK: - Test helpers

/// A one-shot gate: `wait()` returns once `open()` has been called. Lets a
/// test hold an injected install function open long enough to observe the
/// in-flight state, with no sleeps in the assertion path.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor Counter {
    private var count = 0
    func bump() { count += 1 }
    func value() -> Int { count }
}

extension SoundBankDownloadCoordinatorTests {
    /// Polls until the coordinator leaves `.downloading`. The spawned install
    /// task is unstructured, so there is nothing to `await` on directly; this
    /// is the same shape `WhisperModelInstallCoordinatorTests` uses.
    static func settle(_ coordinator: SoundBankDownloadCoordinator,
                       attempts: Int = 400) async {
        for _ in 0..<attempts {
            let state = await coordinator.status().state
            if state != .downloading && state != .idle { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
