import Foundation
import os
import Testing
@testable import AIServices

/// W8-IDR: `SingingEngineInstaller.install` must never lose the child's LAST bytes. The child's
/// exit and its pipes' final bytes reach this process on two unordered paths (the process
/// termination handler, and each pipe's readability handler), so the run may only end once the
/// child exited AND both pipes reached end-of-file — bounded, so a grandchild holding a pipe can
/// never hang the call. Every script here is a FAKE `install.sh` in the test's own temp folder: it
/// writes its one message and exits at once, which is the widest form of that race.
///
/// MEASURED on the run path before this fix: 12 of 1,000 natural runs lost their outcome, and
/// with the handlers paused 5 ms after each read, 1,000 of 1,000 did.

/// A fake `install.sh` in a temp folder of its own. `owner.pid` lets
/// `SingingEngineInstallerTests.swift`'s sweeper reclaim the folder if a crashed run leaks it.
private struct FakeInstallScript {
    let root: URL
    let scriptsDir: URL
    let runtimeDir: URL

    init(body: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sing-installer-drain-\(UUID().uuidString)", isDirectory: true)
        scriptsDir = root.appendingPathComponent("scripts", isDirectory: true)
        runtimeDir = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        try Data(String(getpid()).utf8).write(to: root.appendingPathComponent("owner.pid"))
        try Data(("#!/bin/bash\n" + body + "\n").utf8)
            .write(to: scriptsDir.appendingPathComponent("install.sh"))
    }

    func installer(extraEnvironment: [String: String] = [:]) -> SingingEngineInstaller {
        SingingEngineInstaller(configuration: .init(
            scriptsDir: scriptsDir, runtimeDir: runtimeDir,
            testExtraEnvironment: extraEnvironment))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// The five documented exits, each as a fake script that writes the ONE line its outcome is
/// classified from, then exits at once.
enum SingInstallerFastExit: String, CaseIterable, Sendable {
    case badUsage, failed, succeeded, alreadyRunning, cancelled

    var body: String {
        switch self {
        case .badUsage:
            return "printf '%s\\n' 'line 1 of the pins file is not KEY=value' >&2; exit 2"
        case .failed:
            return "printf '%s\\n' '@@step venv 4/9' '@@error venv the virtual environment could not be built'; exit 1"
        case .succeeded:
            return "printf '%s\\n' '@@done 4832004096'; exit 0"
        case .alreadyRunning:
            return "printf '%s\\n' '@@error preflight another install is running (pid 4242)'; exit 75"
        case .cancelled:
            return "printf '%s\\n' '@@cancelled weights'; exit 143"
        }
    }

    var expected: SingingEngineInstallOutcome {
        switch self {
        case .badUsage: return .badUsage(message: "line 1 of the pins file is not KEY=value")
        case .failed: return .failed(step: "venv", message: "the virtual environment could not be built")
        case .succeeded: return .succeeded(installedBytes: 4_832_004_096)
        case .alreadyRunning: return .alreadyRunning(pid: 4242)
        case .cancelled: return .cancelled(step: "weights")
        }
    }
}

/// Holds every readability-handler call at `.beforeRead` until `releaseAndRearm()`, so the child's
/// bytes are still sitting in the pipe when the bounded end-of-file wait gives up, and only the
/// final drain can deliver them. A held call is released after its run returned; it then finds
/// the run finished and touches nothing. The 5 s timeout only keeps a broken run from wedging.
private final class HandlerStall: Sendable {
    private let current = OSAllocatedUnfairLock(initialState: DispatchSemaphore(value: 0))

    func pause(_ point: SingingEngineInstaller.TestHooks.HandlerPoint) {
        guard point == .beforeRead else { return }
        let semaphore = current.withLock { $0 }
        _ = semaphore.wait(timeout: .now() + .seconds(5))
    }

    func releaseAndRearm() {
        let held = current.withLock { semaphore -> DispatchSemaphore in
            let held = semaphore
            semaphore = DispatchSemaphore(value: 0)
            return held
        }
        // More signals than there can be held calls (one per pipe); a semaphore left above its
        // starting value is safe to release.
        for _ in 0..<4 { held.signal() }
    }
}

/// Runs `kind`'s fake script `runs` times in a row and returns every run whose outcome was not
/// the full expected one (empty = every run kept its last line).
private func misses(
    _ kind: SingInstallerFastExit, runs: Int, label: String,
    configure: (inout SingingEngineInstaller) -> Void = { _ in },
    afterEachRun: () -> Void = {}
) async throws -> [String] {
    let script = try FakeInstallScript(body: kind.body)
    defer { script.remove() }
    var installer = script.installer()
    configure(&installer)
    var missed: [String] = []
    let clock = ContinuousClock()
    let start = clock.now
    for run in 0..<runs {
        let outcome = await installer.install(progress: { _ in })
        afterEachRun()
        if outcome != kind.expected { missed.append("run \(run): \(outcome)") }
    }
    print("W8-IDR \(label) \(kind.rawValue): \(missed.count)/\(runs) runs lost the outcome, \(clock.now - start)")
    return missed
}

@Suite("SingingEngineInstaller.install keeps the child's last bytes (W8-IDR)")
struct SingingEngineInstallerDrainTests {
    static let runs = 200

    // MARK: Natural: no hook, the race as it happens on its own

    @Test("exit 2 + a stderr reason, 200 runs in a row -> every run is .badUsage(that reason)")
    func exit2ReasonSurvivesEveryRun() async throws {
        let missed = try await misses(.badUsage, runs: Self.runs, label: "natural")
        #expect(missed.isEmpty, "\(missed.count)/\(Self.runs) lost: \(missed.prefix(3))")
    }

    @Test("exit 1 + an @@error line, 200 runs in a row -> every run is .failed(step, message)")
    func exit1ErrorLineSurvivesEveryRun() async throws {
        let missed = try await misses(.failed, runs: Self.runs, label: "natural")
        #expect(missed.isEmpty, "\(missed.count)/\(Self.runs) lost: \(missed.prefix(3))")
    }

    @Test("exit 0 + an @@done line, 200 runs in a row -> every run is .succeeded(installedBytes)")
    func exit0DoneLineSurvivesEveryRun() async throws {
        let missed = try await misses(.succeeded, runs: Self.runs, label: "natural")
        #expect(missed.isEmpty, "\(missed.count)/\(Self.runs) lost: \(missed.prefix(3))")
    }

    @Test("exit 75 + the other install's pid, 200 runs in a row -> every run is .alreadyRunning(pid)")
    func exit75PidSurvivesEveryRun() async throws {
        let missed = try await misses(.alreadyRunning, runs: Self.runs, label: "natural")
        #expect(missed.isEmpty, "\(missed.count)/\(Self.runs) lost: \(missed.prefix(3))")
    }

    @Test("exit 143 + an @@cancelled line, 200 runs in a row -> every run is .cancelled(step)")
    func exit143StepSurvivesEveryRun() async throws {
        let missed = try await misses(.cancelled, runs: Self.runs, label: "natural")
        #expect(missed.isEmpty, "\(missed.count)/\(Self.runs) lost: \(missed.prefix(3))")
    }

    // MARK: Hooked: the race made to bite on every run

    /// Each readability handler pauses 5 ms between reading its bytes and parsing them, so those
    /// bytes are still unparsed when the child has exited.
    private static func pauseAfterRead(_ installer: inout SingingEngineInstaller) {
        installer.testHooks = .init(handlerPause: { point in
            if point == .afterRead { usleep(5_000) }
        })
    }

    @Test(
        "every exit kind, 200 runs each with every handler pausing 5 ms after its read -> every run keeps its outcome",
        arguments: SingInstallerFastExit.allCases)
    func everyExitKindSurvivesAPausedHandler(kind: SingInstallerFastExit) async throws {
        let missed = try await misses(kind, runs: Self.runs, label: "paused-after-read", configure: Self.pauseAfterRead)
        #expect(missed.isEmpty, "\(kind.rawValue): \(missed.count)/\(Self.runs) lost: \(missed.prefix(3))")
    }

    @Test(
        """
        every exit kind, 20 runs each with the handlers held PAST a 40 ms end-of-file bound -> \
        the final drain still delivers every outcome
        """,
        arguments: SingInstallerFastExit.allCases)
    func finalDrainDeliversWhenTheHandlersAreStalledPastTheBound(kind: SingInstallerFastExit) async throws {
        let stall = HandlerStall()
        let missed = try await misses(
            kind, runs: 20, label: "stalled-past-bound",
            configure: { installer in
                installer.testHooks = .init(
                    handlerPause: { stall.pause($0) }, eofWaitBound: .milliseconds(40))
            },
            afterEachRun: { stall.releaseAndRearm() })
        #expect(missed.isEmpty, "\(kind.rawValue): \(missed.count)/20 lost: \(missed.prefix(3))")
    }

    // MARK: The bound

    @Test(
        """
        a grandchild holding both pipes open (sleep 30 &), then a reason + exit 2 -> the call \
        returns within the 2 s bound (own clock, < 6 s), with the reason captured
        """)
    func grandchildHoldingThePipesCannotHangTheCall() async throws {
        let script = try FakeInstallScript(body: """
            sleep 30 &
            printf '%s\\n' "$!" > "$W8_IDR_GRANDCHILD_PIDFILE"
            printf '%s\\n' 'line 1 of the pins file is not KEY=value' >&2
            exit 2
            """)
        defer { script.remove() }
        let pidFile = script.root.appendingPathComponent("grandchild.pid")
        defer {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGTERM)
            }
        }
        var installer = script.installer(extraEnvironment: ["W8_IDR_GRANDCHILD_PIDFILE": pidFile.path])
        let waitEndings = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        installer.testHooks = .init(endOfFileWaitEnded: { reached in waitEndings.withLock { $0.append(reached) } })

        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await installer.install(progress: { _ in })
        let elapsed = clock.now - start

        #expect(outcome == .badUsage(message: "line 1 of the pins file is not KEY=value"), "got \(outcome)")
        // The bound's own ceiling, by this test's clock (`.timeLimit` counts in whole minutes).
        #expect(elapsed < .seconds(6), "the call took \(elapsed): a grandchild holding a pipe hung it")
        // Positive controls: the grandchild was still alive when the call returned, and the wait
        // ended on the bound, not on end-of-file — so the return above is the bound's doing, not
        // an absent holder.
        let text = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == 0, "the grandchild (pid \(pid)) was already gone: the test proved nothing")
        #expect(waitEndings.withLock { $0 } == [false], "the wait did not end on the bound")
        #expect(elapsed >= .milliseconds(1_900), "the call returned in \(elapsed): nothing held the pipes")
        print("W8-IDR grandchild: returned in \(elapsed) with \(outcome)")
    }

    @Test(
        """
        a real install.sh run (the local fixture mirror) ends with BOTH pipes at end-of-file: \
        nothing it leaves running holds a pipe, so a real install never waits out the 2 s bound
        """,
        .enabled(if: SingingInstallerFixture.machineHasFixtureInputs))
    func realInstallReachesEndOfFileOnBothPipes() async throws {
        let fixture = try SingingInstallerFixture.requirePaths()
        let scriptsDir = try #require(
            SingingSidecarManager.Configuration.resolveScriptsDir(environment: ProcessInfo.processInfo.environment))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sing-installer-drain-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(String(getpid()).utf8).write(to: root.appendingPathComponent("owner.pid"))
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeDir = root.appendingPathComponent("runtime W8-IDR/App Support/DAWPro/SingingEngine", isDirectory: true)
        let home = root.appendingPathComponent("home of the caller", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var installer = SingingEngineInstaller(configuration: .init(
            scriptsDir: scriptsDir, runtimeDir: runtimeDir,
            installSource: fixture.mirror, pinsFile: fixture.pins,
            testExtraEnvironment: ["HOME": home.path]))
        let waitEndings = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        installer.testHooks = .init(endOfFileWaitEnded: { reached in waitEndings.withLock { $0.append(reached) } })

        let outcome = await installer.install(progress: { _ in })

        guard case .succeeded(let bytes) = outcome else {
            Issue.record("expected .succeeded, got \(outcome)")
            return
        }
        #expect(bytes != nil)
        #expect(waitEndings.withLock { $0 } == [true], "the post-exit wait ended on the 2 s bound: something held a pipe")
    }

    @Test("a cancel before launch -> .cancelled(nil) at once, never waiting out the 2 s end-of-file bound")
    func cancelBeforeLaunchDoesNotWaitForEndOfFile() async throws {
        let script = try FakeInstallScript(body: "exit 0")
        defer { script.remove() }
        let installer = script.installer()

        let clock = ContinuousClock()
        let start = clock.now
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await installer.install(progress: { _ in })
        }
        let outcome = await task.value
        let elapsed = clock.now - start

        #expect(outcome == .cancelled(step: nil), "got \(outcome)")
        #expect(elapsed < .seconds(1), "a never-launched run waited \(elapsed)")
    }

    // MARK: One consumer per stream

    @Test(
        """
        the same @@ stream gives the same progress ticks and outcome whether the readability \
        handler or the final drain reads it
        """)
    func handlerAndDrainParseTheSameWay() async throws {
        let script = try FakeInstallScript(body: """
            printf '%s\\n' '@@step venv 4/9' '@@bytes 10 20' 'not a progress line' '@@step weights 5/9' '@@done 123'
            exit 0
            """)
        defer { script.remove() }
        let expectedTicks = [
            SingingEngineInstallProgress(stepName: "venv", stepIndex: 4, stepCount: 9),
            SingingEngineInstallProgress(stepName: "venv", stepIndex: 4, stepCount: 9, bytesDone: 10, bytesTotal: 20),
            SingingEngineInstallProgress(stepName: "weights", stepIndex: 5, stepCount: 9),
        ]

        // Read by the handler: the plain run.
        let handlerTicks = OSAllocatedUnfairLock<[SingingEngineInstallProgress]>(initialState: [])
        let handlerOutcome = await script.installer().install(progress: { tick in
            handlerTicks.withLock { $0.append(tick) }
        })

        // Read by the final drain: the handlers held past a 40 ms bound.
        let stall = HandlerStall()
        var drained = script.installer()
        drained.testHooks = .init(handlerPause: { stall.pause($0) }, eofWaitBound: .milliseconds(40))
        let drainTicks = OSAllocatedUnfairLock<[SingingEngineInstallProgress]>(initialState: [])
        let drainOutcome = await drained.install(progress: { tick in
            drainTicks.withLock { $0.append(tick) }
        })
        stall.releaseAndRearm()

        #expect(handlerOutcome == .succeeded(installedBytes: 123))
        #expect(drainOutcome == .succeeded(installedBytes: 123))
        #expect(handlerTicks.withLock { $0 } == expectedTicks)
        #expect(drainTicks.withLock { $0 } == expectedTicks)
    }
}
