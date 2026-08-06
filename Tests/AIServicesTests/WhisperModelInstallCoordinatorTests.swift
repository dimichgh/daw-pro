import Foundation
import Testing
@testable import AIServices

// m23-n3b. `WhisperModelInstallCoordinator` is the ONLY thing standing between
// a wire verb and two concurrent `WhisperModelInstaller.install` calls landing
// on the same destination (that installer is a plain, unisolated struct — see
// its own doc). Every test here drives the coordinator through an INJECTED
// `InstallFunction`, never the real installer: the real network leg has never
// executed once in this sandbox (`WhisperModelInstaller`'s own doc — a real
// attempt died at `NSURLErrorDomain -1001` after 61.6s with zero bytes moved),
// and this seam is the only way progress-through-status can be exercised at
// all, per the item's own instructions.

// MARK: - Fixture

private func fixtureDescriptor(variant: String) -> WhisperModelDescriptor {
    // A value only — nothing here is ever read from or written to disk.
    let base = URL(fileURLWithPath: "/private/tmp/whisper-coordinator-fixture-\(UUID().uuidString)")
    return WhisperModelDescriptor(
        variantDirectoryName: variant,
        displayName: variant,
        modelFolder: base.appendingPathComponent(variant),
        tokenizerFolder: base.appendingPathComponent(variant).appendingPathComponent("tokenizer"),
        modelSizeBytes: 1024,
        tokenizerSizeBytes: 128,
        hasContextPrefill: false,
        // m23-n3f: stated, not defaulted — the descriptor is a value here, and a
        // default would let a construction site forget the capability exists.
        supportsWordTimestamps: true)
}

/// A gated test double for `WhisperModelInstallCoordinator.InstallFunction`.
///
/// `function(...)` records that it was called (and, via `peakConcurrent`,
/// whether more than one call was EVER inside it at once — the n2a-style
/// observable that "the second start() call threw" alone cannot provide),
/// optionally emits a scripted sequence of progress ticks synchronously, then
/// suspends until the test calls `release()`. That gate is what makes it
/// possible to poll the coordinator's `status()` mid-install and prove
/// progress is visible WHILE installing, not only in the terminal snapshot.
private actor InstallProbe {
    enum ProbeError: Error, Equatable { case unconfigured }

    private(set) var totalCalls = 0
    private(set) var peakConcurrent = 0
    private var active = 0
    private var released = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    private var scriptedProgress: [WhisperModelInstallProgress] = []
    private var outcome: Result<WhisperModelDescriptor, Error> = .failure(ProbeError.unconfigured)

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

    /// Matches `WhisperModelInstallCoordinator.InstallFunction`.
    func function(
        variant: String,
        overwrite: Bool,
        repo: String,
        token: String?,
        progress: @escaping @Sendable (WhisperModelInstallProgress) -> Void
    ) async throws -> WhisperModelDescriptor {
        totalCalls += 1
        active += 1
        peakConcurrent = max(peakConcurrent, active)
        for tick in scriptedProgress { progress(tick) }
        await waitForRelease()
        active -= 1
        switch outcome {
        case .success(let descriptor): return descriptor
        case .failure(let error): throw error
        }
    }

    /// Wraps `function` as the closure type the coordinator's initializer
    /// wants — the actor method itself can't satisfy that type directly.
    nonisolated var asInstallFunction: WhisperModelInstallCoordinator.InstallFunction {
        { [self] variant, overwrite, repo, token, progress in
            try await self.function(
                variant: variant, overwrite: overwrite, repo: repo, token: token, progress: progress)
        }
    }
}

/// Polls `status()` until it leaves `.installing` or the timeout elapses.
/// Every path exercised in these tests either completes promptly (the probe
/// is released synchronously in the same test) or is expected to still be
/// `.installing` when this returns (the timeout fires harmlessly and the test
/// asserts on that fact) — never used to paper over a hang.
private func waitForTerminal(
    _ coordinator: WhisperModelInstallCoordinator,
    timeoutNanoseconds: UInt64 = 2_000_000_000
) async -> WhisperModelInstallStatus {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    var status = await coordinator.status()
    while status.state == .installing, DispatchTime.now().uptimeNanoseconds < deadline {
        try? await Task.sleep(nanoseconds: 2_000_000)
        status = await coordinator.status()
    }
    return status
}

/// Polls `status()` until progress is visible or a terminal state is reached.
private func waitForProgress(
    _ coordinator: WhisperModelInstallCoordinator,
    timeoutNanoseconds: UInt64 = 2_000_000_000
) async -> WhisperModelInstallStatus {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    var status = await coordinator.status()
    while status.progress == nil, status.state == .installing,
          DispatchTime.now().uptimeNanoseconds < deadline {
        try? await Task.sleep(nanoseconds: 2_000_000)
        status = await coordinator.status()
    }
    return status
}

// MARK: - The gate

@Suite("Whisper model install coordinator (m23-n3b)")
struct WhisperModelInstallCoordinatorTests {

    // MARK: Idle / lifecycle basics

    @Test("status is idle before anything has ever started")
    func idleBeforeStart() async {
        let coordinator = WhisperModelInstallCoordinator(installFunction: { _, _, _, _, _ in
            Issue.record("install function must not be called")
            throw InstallProbe.ProbeError.unconfigured
        })
        let status = await coordinator.status()
        #expect(status == .idle)
    }

    @Test("start returns an .installing snapshot immediately, before the install call resolves")
    func startReturnsImmediately() async throws {
        let probe = InstallProbe()
        await probe.configure(outcome: .success(fixtureDescriptor(variant: "openai_whisper-tiny.en")))
        let coordinator = WhisperModelInstallCoordinator(installFunction: probe.asInstallFunction)

        let started = try await coordinator.start(variant: "tiny.en")
        #expect(started.state == .installing)
        #expect(started.variantDirectoryNameRequested == "tiny.en")
        #expect(started.descriptor == nil)
        #expect(started.errorMessage == nil)

        // Still gated: the fake has not been told to return yet, so polling
        // again must still read .installing, not something derived from a
        // return that has not happened.
        let stillInstalling = await coordinator.status()
        #expect(stillInstalling.state == .installing)

        await probe.release()
        let finished = await waitForTerminal(coordinator)
        #expect(finished.state == .succeeded)
        #expect(finished.descriptor?.variantDirectoryName == "openai_whisper-tiny.en")
    }

    // MARK: Progress — visible WHILE installing, not just in the terminal record

    @Test("a progress tick emitted by the install function is visible through status while installing")
    func progressVisibleDuringInstall() async throws {
        let probe = InstallProbe()
        let tick = WhisperModelInstallProgress(
            phase: .downloadingModel, variantDirectoryName: "openai_whisper-tiny.en",
            phaseFraction: 0.42, completedUnitCount: 42, totalUnitCount: 100)
        await probe.configure(
            scriptedProgress: [tick],
            outcome: .success(fixtureDescriptor(variant: "openai_whisper-tiny.en")))
        let coordinator = WhisperModelInstallCoordinator(installFunction: probe.asInstallFunction)

        _ = try await coordinator.start(variant: "tiny.en")
        let observed = await waitForProgress(coordinator)
        // Caught WHILE installing — the probe is still gated at this point,
        // so this cannot be reading a value that leaked from the terminal
        // record instead of the live one.
        #expect(observed.state == .installing)
        #expect(observed.progress == tick)

        await probe.release()
        let finished = await waitForTerminal(coordinator)
        #expect(finished.state == .succeeded)
        // Survives into the terminal snapshot too.
        #expect(finished.progress == tick)
    }

    @Test("a download that never calls progress still reaches a terminal state, with progress nil")
    func terminalWithoutProgress() async throws {
        let probe = InstallProbe()
        await probe.configure(
            scriptedProgress: [],
            outcome: .success(fixtureDescriptor(variant: "openai_whisper-base")))
        let coordinator = WhisperModelInstallCoordinator(installFunction: probe.asInstallFunction)

        _ = try await coordinator.start(variant: "base")
        await probe.release()
        let finished = await waitForTerminal(coordinator)

        #expect(finished.state == .succeeded)
        #expect(finished.progress == nil)
        #expect(finished.descriptor?.variantDirectoryName == "openai_whisper-base")
    }

    @Test("a failed install reaches .failed with the underlying error's readable message, descriptor nil")
    func terminalFailure() async throws {
        let probe = InstallProbe()
        await probe.configure(outcome: .failure(WhisperModelInstallError.unrecognisedVariant(
            requested: "openai_whisper-enormous", known: ["tiny", "base"])))
        let coordinator = WhisperModelInstallCoordinator(installFunction: probe.asInstallFunction)

        _ = try await coordinator.start(variant: "openai_whisper-enormous")
        await probe.release()
        let finished = await waitForTerminal(coordinator)

        #expect(finished.state == .failed)
        #expect(finished.descriptor == nil)
        #expect(finished.errorMessage?.contains("openai_whisper-enormous") == true)
    }

    @Test("a second install starts clean — the previous install's progress does not bleed into it")
    func secondInstallDoesNotInheritStaleProgress() async throws {
        let probe = InstallProbe()
        let firstTick = WhisperModelInstallProgress(
            phase: .downloadingModel, variantDirectoryName: "openai_whisper-tiny.en",
            phaseFraction: 0.97, completedUnitCount: 97, totalUnitCount: 100)
        await probe.configure(
            scriptedProgress: [firstTick],
            outcome: .success(fixtureDescriptor(variant: "openai_whisper-tiny.en")))
        let coordinator = WhisperModelInstallCoordinator(installFunction: probe.asInstallFunction)

        _ = try await coordinator.start(variant: "tiny.en")
        await probe.release()
        let first = await waitForTerminal(coordinator)
        #expect(first.state == .succeeded)
        #expect(first.progress == firstTick)

        // A SECOND install, of a different variant, which has not ticked yet.
        // `configure` re-gates the probe, so this one is still suspended
        // inside the install function when `status()` is read below.
        await probe.configure(
            scriptedProgress: [],
            outcome: .success(fixtureDescriptor(variant: "openai_whisper-large-v3")))

        _ = try await coordinator.start(variant: "large-v3")
        let second = await coordinator.status()

        // THE POINT: a freshly-started multi-GB download must not report the
        // PREVIOUS install's 97% until its own first tick lands. `start()`
        // clearing the progress box is what makes that true, and no other
        // test in this suite reads status ACROSS two installs — so without
        // this one, that line can be deleted with all 7 staying green
        // (verified by mutation, m23-n3b orchestrator pass).
        #expect(second.state == .installing)
        #expect(second.variantDirectoryNameRequested == "large-v3")
        #expect(second.progress == nil,
                "stale progress from the previous install bled into a fresh one")

        await probe.release()
        let finished = await waitForTerminal(coordinator)
        #expect(finished.state == .succeeded)
    }

    // MARK: The refusal, sequential

    @Test("a second start while one is installing is refused, naming both variants; no queueing")
    func refusesSecondStartWhileInstalling() async throws {
        let probe = InstallProbe()
        await probe.configure(outcome: .success(fixtureDescriptor(variant: "a")))
        let coordinator = WhisperModelInstallCoordinator(installFunction: probe.asInstallFunction)

        _ = try await coordinator.start(variant: "a")
        do {
            _ = try await coordinator.start(variant: "b")
            Issue.record("expected installAlreadyInFlight")
        } catch WhisperModelInstallCoordinatorError.installAlreadyInFlight(let requested, let inFlight) {
            #expect(requested == "b")
            #expect(inFlight == "a")
        } catch {
            Issue.record("expected installAlreadyInFlight, got \(error)")
        }

        // Not queued: releasing "a" and letting it finish does NOT retroactively
        // start "b" — a fresh start call is required.
        await probe.release()
        let finishedA = await waitForTerminal(coordinator)
        #expect(finishedA.state == .succeeded)
        #expect(finishedA.variantDirectoryNameRequested == "a")

        // Now that "a" is done, "b" is accepted.
        await probe.configure(outcome: .success(fixtureDescriptor(variant: "b")))
        _ = try await coordinator.start(variant: "b")
        let installingB = await coordinator.status()
        #expect(installingB.state == .installing)
        #expect(installingB.variantDirectoryNameRequested == "b")
    }

    // MARK: THE concurrency hazard — proven with an observable, not just a throw

    @Test("only one install is EVER in flight, even under concurrent start attempts")
    func onlyOneInstallInFlightUnderConcurrentStarts() async throws {
        let probe = InstallProbe()
        await probe.configure(outcome: .success(fixtureDescriptor(variant: "openai_whisper-tiny.en")))
        let coordinator = WhisperModelInstallCoordinator(installFunction: probe.asInstallFunction)

        let attemptCount = 8
        let accepted: [Bool] = await withTaskGroup(of: Bool.self) { group in
            for i in 0..<attemptCount {
                group.addTask {
                    do {
                        _ = try await coordinator.start(variant: "variant-\(i)")
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var collected: [Bool] = []
            for await result in group { collected.append(result) }
            return collected
        }

        // Exactly one of the N concurrent attempts was accepted — the rest
        // were refused, never queued.
        #expect(accepted.filter { $0 }.count == 1)
        #expect(accepted.filter { !$0 }.count == attemptCount - 1)

        await probe.release()
        _ = await waitForTerminal(coordinator)

        // THE leg that actually sees the invariant rather than inferring it:
        // the underlying install function was invoked exactly once, and never
        // had more than one caller inside it at the same time. "The second
        // start() call threw" alone could pass even if the guard were broken
        // in a way that still happened to serialize by luck — this cannot.
        #expect(await probe.totalCalls == 1)
        #expect(await probe.peakConcurrent == 1)
    }
}
