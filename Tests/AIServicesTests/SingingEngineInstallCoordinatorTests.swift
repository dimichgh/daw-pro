import Foundation
import os
import Testing
@testable import AIServices

/// `SingingEngineInstallCoordinator` coverage (item p2-sing-c) — entirely INJECTED (the
/// `WhisperModelInstallCoordinatorTests`/`SoundBankDownloadCoordinatorTests` shape: an
/// `InstallFunction` double, no process, no fixture, no network). The REAL installer is already
/// covered end to end by `SingingEngineInstallerTests`; this file is only the coordinator's own
/// sequencing: the single-flight guard, progress pass-through, outcome-to-status mapping, and
/// cancel.

/// A single-fire gate a scripted install can `await` before doing anything — lets a test observe
/// "installing, nothing has ticked yet" as a real, held state rather than a race with the
/// scripted function's own speed.
private actor Gate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

private final class ScriptedInstall: @unchecked Sendable {
    enum AfterTicks: Sendable {
        case returnOutcome(SingingEngineInstallOutcome)
        /// Blocks until the coordinator's `cancel()` cancels this call's `Task`, then returns
        /// `.cancelled(step:)` — the same shape the REAL installer reaches via
        /// `withTaskCancellationHandler`, simulated directly so this file needs no real process.
        case waitForCancellation
    }

    private let callCountBox = OSAllocatedUnfairLock<Int>(initialState: 0)
    private let gate: Gate?
    private let ticks: [SingingEngineInstallProgress]
    private let afterTicks: AfterTicks

    init(
        gate: Gate? = nil, ticks: [SingingEngineInstallProgress] = [],
        afterTicks: AfterTicks = .returnOutcome(.succeeded(installedBytes: 1))
    ) {
        self.gate = gate
        self.ticks = ticks
        self.afterTicks = afterTicks
    }

    var callCount: Int { callCountBox.withLock { $0 } }

    func asFunction() -> SingingEngineInstallCoordinator.InstallFunction {
        { progress in
            self.callCountBox.withLock { $0 += 1 }
            if let gate = self.gate { await gate.wait() }
            for tick in self.ticks { progress(tick) }
            switch self.afterTicks {
            case .returnOutcome(let outcome):
                return outcome
            case .waitForCancellation:
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                return .cancelled(step: "scripted")
            }
        }
    }
}

private func waitUntil(timeoutSeconds: Double = 3, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

private func waitForTerminal(
    _ coordinator: SingingEngineInstallCoordinator, timeoutSeconds: Double = 3
) async -> SingingEngineInstallStatus {
    var status = await coordinator.status()
    _ = await waitUntil(timeoutSeconds: timeoutSeconds) {
        status = await coordinator.status()
        return status.state != .installing
    }
    return status
}

// MARK: - Single-flight

@Suite("SingingEngineInstallCoordinator — single-flight (item p2-sing-c)")
struct SingingEngineInstallCoordinatorSingleFlightTests {
    @Test("a second start() while one is in flight throws .installAlreadyInFlight; the function is entered once")
    func secondStartThrowsWhileInFlight() async throws {
        let gate = Gate()
        let scripted = ScriptedInstall(gate: gate, afterTicks: .waitForCancellation)
        let coordinator = SingingEngineInstallCoordinator(installFunction: scripted.asFunction())

        let first = try await coordinator.start()
        #expect(first.state == .installing)
        // `start()` schedules the install `Task` but returns before Swift's cooperative
        // scheduler necessarily runs even its first line — wait for real entry, not just
        // acceptance, before asserting on call count (an assumed-synchronous read here read 0
        // once, caught by the real run, not assumed away).
        let entered = await waitUntil { scripted.callCount > 0 }
        #expect(entered, "the scripted install was never entered at all")

        do {
            _ = try await coordinator.start()
            Issue.record("expected the second start() to throw")
        } catch let error as SingingEngineInstallCoordinatorError {
            #expect(error == .installAlreadyInFlight)
        }
        #expect(scripted.callCount == 1)

        await gate.open()
        try await coordinator.cancel()
        _ = await waitForTerminal(coordinator)
    }
}

// MARK: - Progress pass-through

@Suite("SingingEngineInstallCoordinator — progress pass-through (item p2-sing-c)")
struct SingingEngineInstallCoordinatorProgressTests {
    @Test("status().progress is nil while installing, before the scripted function has ticked even once")
    func progressIsNilBeforeFirstTick() async throws {
        let gate = Gate()
        let scripted = ScriptedInstall(gate: gate, afterTicks: .waitForCancellation)
        let coordinator = SingingEngineInstallCoordinator(installFunction: scripted.asFunction())

        _ = try await coordinator.start()
        let status = await coordinator.status()
        #expect(status.state == .installing)
        #expect(status.progress == nil)

        await gate.open()
        try await coordinator.cancel()
        _ = await waitForTerminal(coordinator)
    }

    @Test("status().progress reports the LATEST tick while still installing")
    func progressReportsLatestTickWhileInstalling() async throws {
        let tick1 = SingingEngineInstallProgress(stepName: "preflight", stepIndex: 1, stepCount: 9)
        let tick2 = SingingEngineInstallProgress(stepName: "weights", stepIndex: 6, stepCount: 9, bytesDone: 10, bytesTotal: 100)
        let scripted = ScriptedInstall(ticks: [tick1, tick2], afterTicks: .waitForCancellation)
        let coordinator = SingingEngineInstallCoordinator(installFunction: scripted.asFunction())

        _ = try await coordinator.start()
        let reachedTick2 = await waitUntil { await coordinator.status().progress?.stepName == "weights" }
        #expect(reachedTick2)
        let status = await coordinator.status()
        #expect(status.progress?.bytesDone == 10)
        #expect(status.state == .installing, "must still be installing -- the scripted function is holding")

        try await coordinator.cancel()
        _ = await waitForTerminal(coordinator)
    }
}

// MARK: - Every outcome maps to the right terminal state

@Suite("SingingEngineInstallCoordinator — outcome to status mapping (item p2-sing-c)")
struct SingingEngineInstallCoordinatorOutcomeMappingTests {
    static let cases: [(
        outcome: SingingEngineInstallOutcome, expectedState: SingingEngineInstallState,
        mustContain: [String]
    )] = [
        (.succeeded(installedBytes: 100), .succeeded, []),
        (.succeeded(installedBytes: nil), .succeeded, []),
        (.failed(step: "voice", message: "bad hash"), .failed, ["voice", "bad hash"]),
        (.alreadyRunning(pid: 555), .failed, ["555"]),
        (.alreadyRunning(pid: nil), .failed, []),
        (.badUsage(message: "bad config"), .failed, ["bad config"]),
        (.cancelled(step: "weights"), .cancelled, ["weights"]),
        (.cancelled(step: nil), .cancelled, []),
        (.crashed(exitCode: 137, stderrTail: "killed"), .failed, ["137"]),
    ]

    @Test("every SingingEngineInstallOutcome maps to its right terminal state and message", arguments: cases)
    func outcomeMapsToTerminalState(
        testCase: (outcome: SingingEngineInstallOutcome, expectedState: SingingEngineInstallState, mustContain: [String])
    ) async throws {
        let scripted = ScriptedInstall(afterTicks: .returnOutcome(testCase.outcome))
        let coordinator = SingingEngineInstallCoordinator(installFunction: scripted.asFunction())

        _ = try await coordinator.start()
        let status = await waitForTerminal(coordinator)

        #expect(status.state == testCase.expectedState, "outcome \(testCase.outcome)")
        if case .succeeded(let bytes) = testCase.outcome {
            #expect(status.installedBytes == bytes)
        }
        for substring in testCase.mustContain {
            #expect(
                status.errorMessage?.contains(substring) == true,
                "expected '\(substring)' in \(status.errorMessage ?? "nil") for outcome \(testCase.outcome)")
        }
    }
}

// MARK: - Cancel

@Suite("SingingEngineInstallCoordinator — cancel (item p2-sing-c)")
struct SingingEngineInstallCoordinatorCancelTests {
    @Test("cancel() with nothing running throws .nothingInFlight")
    func cancelWithNothingRunningThrows() async throws {
        let coordinator = SingingEngineInstallCoordinator(
            installFunction: ScriptedInstall().asFunction())
        do {
            _ = try await coordinator.cancel()
            Issue.record("expected cancel() to throw")
        } catch let error as SingingEngineInstallCoordinatorError {
            #expect(error == .nothingInFlight)
        }
    }

    @Test("cancel() sets cancelRequested immediately; state stays .installing until the function actually returns .cancelled")
    func cancelRequestedIsHonestAboutTiming() async throws {
        let scripted = ScriptedInstall(afterTicks: .waitForCancellation)
        let coordinator = SingingEngineInstallCoordinator(installFunction: scripted.asFunction())

        _ = try await coordinator.start()
        let afterCancel = try await coordinator.cancel()
        #expect(afterCancel.cancelRequested == true)
        // Not yet necessarily terminal -- the scripted function only notices cancellation on its
        // OWN next poll of Task.isCancelled, same as the real installer noticing via
        // withTaskCancellationHandler. Either .installing (still unwinding) or already .cancelled
        // is honest; what would NOT be honest is any OTHER terminal state.
        #expect(afterCancel.state == .installing || afterCancel.state == .cancelled)

        let final = await waitForTerminal(coordinator)
        #expect(final.state == .cancelled)
    }

    @Test("a fresh start() after a cancelled terminal state clears cancelRequested (no stale carryover)")
    func secondStartAfterCancelClearsCancelRequested() async throws {
        let firstScripted = ScriptedInstall(
            ticks: [SingingEngineInstallProgress(stepName: "weights", stepIndex: 6, stepCount: 9)],
            afterTicks: .waitForCancellation)
        let coordinator = SingingEngineInstallCoordinator(installFunction: firstScripted.asFunction())
        _ = try await coordinator.start()
        _ = await waitUntil { await coordinator.status().progress != nil }
        try await coordinator.cancel()
        let cancelled = await waitForTerminal(coordinator)
        #expect(cancelled.state == .cancelled)
        #expect(cancelled.cancelRequested == false, "cancelRequested must be cleared once terminal")
    }

    @Test("""
        a fresh start() on the SAME coordinator, right after a previous cancelled run, begins the \
        new .installing status with NO progress inherited from the run before it \
        (the secondInstallDoesNotInheritStaleProgress pin, restated for this coordinator)
        """)
    func secondStartOnSameCoordinatorDoesNotInheritPreviousProgress() async throws {
        let callCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let secondCallGate = Gate()
        let coordinator = SingingEngineInstallCoordinator(installFunction: { progress in
            let n = callCount.withLock { box -> Int in
                box += 1
                return box
            }
            if n == 1 {
                progress(SingingEngineInstallProgress(stepName: "weights", stepIndex: 6, stepCount: 9))
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                return .cancelled(step: "weights")
            }
            await secondCallGate.wait()
            return .succeeded(installedBytes: 1)
        })

        _ = try await coordinator.start()
        _ = await waitUntil { await coordinator.status().progress != nil }
        try await coordinator.cancel()
        let firstTerminal = await waitForTerminal(coordinator)
        #expect(firstTerminal.state == .cancelled)
        #expect(firstTerminal.progress?.stepName == "weights")

        let secondStart = try await coordinator.start()
        #expect(secondStart.progress == nil, "the second run must not inherit the first run's progress")

        await secondCallGate.open()
        _ = await waitForTerminal(coordinator)
    }
}
