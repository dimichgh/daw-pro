import Foundation
import os
import Testing
@testable import AIServices

/// `SingingEngineInstaller` coverage (item p2-sing-c): the pure line-grammar/reducer/classifier
/// tables need no process at all; the real-install/re-run/cancel/badUsage suites run
/// `scripts/sing/install.sh` for real against the LOCAL FIXTURE MIRROR
/// (`scripts/sing/tests/fixture_mirror.py`) — never the network, never the real engine, per the
/// design's own gate text.

private func testScriptsDir() throws -> URL {
    try #require(
        SingingSidecarManager.Configuration.resolveScriptsDir(
            environment: ProcessInfo.processInfo.environment),
        "scripts/sing could not be resolved — run from inside the daw-pro checkout")
}

// MARK: - The fixture mirror, built ONCE per test process

/// Built lazily, once, the first time any gated test touches it — Swift's `static let`
/// initialization guarantee is the `test_install.py setUpClass` equivalent achieved without a
/// class-level test lifecycle hook (Swift Testing structs have none). No new file is added under
/// `scripts/sing/` (read-only from this item, per its own brief) — the build runs via an inline
/// `python3 -c` script importing `fixture_mirror` directly, and nothing here hardcodes a
/// session-specific path: the mirror lands in a fresh `NSTemporaryDirectory()` folder every time
/// this test process runs, exactly like `fixture_mirror.build`'s own Python callers already do.
enum SingingInstallerFixture {
    struct Paths: Sendable {
        var mirror: URL
        var pins: URL
        var modelSha256: String
        var builtinWavSha256: String
    }

    /// Mirrors `fixture_mirror.missing_inputs()`'s exact 6 paths, filesystem-only (no subprocess),
    /// so `.enabled(if:)` gating costs nothing on a machine that lacks the spike.
    static var machineHasFixtureInputs: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let spike = home.appendingPathComponent("DAWPro-spikes/sing-soulx", isDirectory: true)
        let need = [
            home.appendingPathComponent(".local/bin/uv").path,
            spike.appendingPathComponent(
                "python/cpython-3.10.20-macos-aarch64-none/bin/python3.10"
            ).path,
            spike.appendingPathComponent("src/SoulX-Singer/example/audio/zh_prompt.mp3").path,
            spike.appendingPathComponent("src/SoulX-Singer/example/audio/zh_prompt.json").path,
            "/usr/bin/git", "/usr/bin/tar",
        ]
        return need.allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }

    static let built: Result<Paths, InstallerFixtureError> = {
        guard machineHasFixtureInputs else {
            return .failure(.buildFailed("this machine is missing one of fixture_mirror.missing_inputs()'s 6 paths"))
        }
        guard let scriptsDir = try? testScriptsDir() else {
            return .failure(.buildFailed("scripts/sing could not be resolved"))
        }
        // FIX NOW #5 hygiene: sweep any PREVIOUS process's dead mirror build before adding ours —
        // see `sweepDeadSingInstallerRoots`'s doc. This is the "leaks one mirror build every run"
        // leak the architect named; there is no `defer` for a `static let` shared for the whole
        // test PROCESS's lifetime, so the NEXT process is what cleans this one up.
        sweepDeadSingInstallerRoots()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sing-installer-fixture-\(UUID().uuidString)", isDirectory: true)
        let mirrorDir = tmp.appendingPathComponent("mirror", isDirectory: true)
        let workDir = tmp.appendingPathComponent("work", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        } catch {
            return .failure(.buildFailed("could not create the fixture temp dir: \(error)"))
        }
        markOwner(of: tmp)
        let script = """
            import sys, json
            sys.path.insert(0, \(pythonLiteral(scriptsDir.appendingPathComponent("tests").path)))
            import fixture_mirror
            built = fixture_mirror.build(\(pythonLiteral(mirrorDir.path)), \(pythonLiteral(workDir.path)))
            print(json.dumps(built))
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return .failure(.buildFailed("could not launch python3: \(error)"))
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return .failure(.buildFailed(
                "fixture_mirror.build exited \(process.terminationStatus): "
                    + (String(data: errData, encoding: .utf8) ?? "")))
        }
        guard let json = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
              let mirror = json["mirror"] as? String, let pins = json["pins"] as? String,
              let facts = json["facts"] as? [String: Any],
              let modelSha = facts["model_sha256"] as? String,
              let builtinSha = facts["builtin_wav_sha256"] as? String
        else {
            return .failure(.buildFailed("fixture_mirror.build produced unparseable JSON"))
        }
        return .success(Paths(
            mirror: URL(fileURLWithPath: mirror), pins: URL(fileURLWithPath: pins),
            modelSha256: modelSha, builtinWavSha256: builtinSha))
    }()

    static func requirePaths() throws -> Paths {
        switch built {
        case .success(let paths): return paths
        case .failure(let error): throw error
        }
    }

    enum InstallerFixtureError: Error, CustomStringConvertible {
        case buildFailed(String)
        var description: String {
            switch self { case .buildFailed(let reason): return "fixture mirror build failed: \(reason)" }
        }
    }
}

private func pythonLiteral(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

// MARK: - `sing-installer-*` temp-dir hygiene (FIX NOW #5, registered while #5 is edited)
//
// Every `sing-installer-fixture-*`/`sing-installer-test-*` root this file creates writes its
// OWN pid into an `owner.pid` marker right after creation — the project's own pidfile idiom,
// restated for a /tmp root instead of a runtime dir. A LATER test process sweeps any root whose
// marked owner is no longer alive (`kill(pid,0)` reports ESRCH) before creating its own. This
// catches BOTH the common case (a normal test run leaks its root — caller `defer`s it away
// immediately below) AND the crash case (this suite has produced real signal-6 aborts; neither
// `defer` nor `atexit` fires on a trapped signal, so a crashed run's leftovers wait for the NEXT
// process to sweep them, rather than accumulating forever). A root with NO marker yet is never
// touched — it may be an in-flight build from a racing process (unlikely under this project's
// one-heavy-slot convention, but the marker check costs nothing to keep anyway).
private func markOwner(of root: URL) {
    try? Data(String(getpid()).utf8).write(to: root.appendingPathComponent("owner.pid"))
}

private func sweepDeadSingInstallerRoots() {
    let tmp = FileManager.default.temporaryDirectory
    guard let entries = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
    else { return }
    for entry in entries where entry.lastPathComponent.hasPrefix("sing-installer-") {
        guard let data = try? Data(contentsOf: entry.appendingPathComponent("owner.pid")),
              let pid = Int32(String(decoding: data, as: UTF8.self))
        else { continue }
        if kill(pid, 0) != 0 {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}

/// A runtime dir WITH A SPACE in the path — `.../runtime <tag>/App Support/DAWPro/SingingEngine`
/// — SB's own F14 requirement (design §8): "Application Support" has a space in every real
/// install, and install.sh is documented QUOTED throughout specifically because of it.
/// Returns `root` alongside `dir` so a caller can `defer { removeItem(at: root) }` — `dir` is
/// several components BELOW `root` and removing it alone would not reclaim the UUID-named parent.
private func testRuntimeDir(tag: String) throws -> (dir: URL, root: URL) {
    sweepDeadSingInstallerRoots()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sing-installer-test-\(UUID().uuidString)", isDirectory: true)
    let dir = root
        .appendingPathComponent("runtime \(tag)", isDirectory: true)
        .appendingPathComponent("App Support/DAWPro/SingingEngine", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    markOwner(of: root)
    return (dir: dir, root: root)
}

private final class ProgressCollector: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[SingingEngineInstallProgress]>(initialState: [])
    /// Resumed on the FIRST tick that carries a `.bytes` update — the exact signal the cancel
    /// test needs (advisor's guidance: wait for a real `@@bytes` line, never a fixed sleep, or the
    /// cancel races the download and lands on the wrong step, or none at all). `nil` covers BOTH
    /// "nothing has registered yet" and "already resumed" — `record` treats both identically (do
    /// nothing), so one optional is enough; `?.resume()` on `nil` is a safe no-op.
    private let continuationBox = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)

    func record(_ tick: SingingEngineInstallProgress) {
        lock.withLock { $0.append(tick) }
        if tick.bytesDone != nil {
            continuationBox.withLock { continuation in
                continuation?.resume()
                continuation = nil
            }
        }
    }

    var ticks: [SingingEngineInstallProgress] { lock.withLock { $0 } }

    /// Suspends until the first `.bytes` tick arrives, or returns immediately if one already has.
    func waitForFirstBytesTick() async {
        let alreadyHappened = lock.withLock { $0.contains { $0.bytesDone != nil } }
        if alreadyHappened { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            continuationBox.withLock { $0 = continuation }
        }
    }
}

// MARK: - The pure line grammar

@Suite("SingingEngineInstallLine.parse — install.sh's own doc table, verbatim (item p2-sing-c)")
struct SingingEngineInstallLineParseTests {
    @Test("@@step preflight 1/9 -> .step(name: preflight, index: 1, count: 9)")
    func parsesStep() {
        #expect(SingingEngineInstallLine.parse("@@step preflight 1/9")
                == .step(name: "preflight", index: 1, count: 9))
    }

    @Test("@@skip uv -> .skip(name: uv)")
    func parsesSkip() {
        #expect(SingingEngineInstallLine.parse("@@skip uv") == .skip(name: "uv"))
    }

    @Test("@@bytes 1048576 4193000000 -> .bytes(done:total:)")
    func parsesBytes() {
        #expect(SingingEngineInstallLine.parse("@@bytes 1048576 4193000000")
                == .bytes(done: 1_048_576, total: 4_193_000_000))
    }

    @Test("@@free 123456 -> .free(kb: 123456)")
    func parsesFree() {
        #expect(SingingEngineInstallLine.parse("@@free 123456") == .free(kb: 123_456))
    }

    @Test("@@error voice <message with several words> -> .error(step: voice, message: verbatim)")
    func parsesErrorWithSpacedMessage() {
        let line = "@@error voice the built-in voice did not rebuild to the bytes you picked"
        #expect(SingingEngineInstallLine.parse(line)
                == .error(step: "voice", message: "the built-in voice did not rebuild to the bytes you picked"))
    }

    @Test("@@cancelled weights -> .cancelled(step: weights)")
    func parsesCancelled() {
        #expect(SingingEngineInstallLine.parse("@@cancelled weights") == .cancelled(step: "weights"))
    }

    @Test("@@done 4832004096 -> .done(installedBytes: 4832004096)")
    func parsesDone() {
        #expect(SingingEngineInstallLine.parse("@@done 4832004096") == .done(installedBytes: 4_832_004_096))
    }

    @Test("a line that is not @@-prefixed -> nil (that is stderr's channel, not this one)")
    func nonAtAtLineIsNil() {
        #expect(SingingEngineInstallLine.parse("install.sh: starting preflight") == nil)
    }

    @Test("a malformed @@step (missing the i/n pair) -> nil, never a crash")
    func malformedStepIsNil() {
        #expect(SingingEngineInstallLine.parse("@@step preflight") == nil)
        #expect(SingingEngineInstallLine.parse("@@step preflight one/nine") == nil)
    }

    @Test("an unrecognised @@ tag -> nil")
    func unknownTagIsNil() {
        #expect(SingingEngineInstallLine.parse("@@somethingNew a b c") == nil)
    }

    @Test("pid(inAlreadyRunningMessage:) extracts the pid from install.sh's own literal wording")
    func pidExtractedFromAlreadyRunningMessage() {
        #expect(SingingEngineInstallLine.pid(
            inAlreadyRunningMessage: "another install is running (pid 12345)") == 12345)
    }

    @Test("pid(inAlreadyRunningMessage:) is nil for a message that does not have that shape")
    func pidIsNilForUnshapedMessage() {
        #expect(SingingEngineInstallLine.pid(inAlreadyRunningMessage: "something else entirely") == nil)
    }
}

// MARK: - The pure progress reducer

@Suite("SingingEngineInstallProgress.applying — the pure reducer (item p2-sing-c)")
struct SingingEngineInstallProgressApplyingTests {
    @Test("a .step resets the byte fields to nil — a new step never inherits the last one's fraction")
    func stepResetsBytes() {
        let afterBytes = SingingEngineInstallProgress(
            stepName: "weights", stepIndex: 6, stepCount: 9, bytesDone: 500, bytesTotal: 1000)
        let next = SingingEngineInstallProgress.applying(
            .step(name: "nltk", index: 7, count: 9), to: afterBytes)
        #expect(next.stepName == "nltk")
        #expect(next.stepIndex == 7)
        #expect(next.bytesDone == nil)
        #expect(next.bytesTotal == nil)
    }

    @Test(".bytes after .step updates ONLY the byte fields")
    func bytesUpdatesOnlyBytes() {
        let afterStep = SingingEngineInstallProgress.applying(
            .step(name: "weights", index: 6, count: 9), to: nil)
        let next = SingingEngineInstallProgress.applying(.bytes(done: 10, total: 100), to: afterStep)
        #expect(next.stepName == "weights")
        #expect(next.stepIndex == 6)
        #expect(next.bytesDone == 10)
        #expect(next.bytesTotal == 100)
    }

    @Test(".free persists across a LATER .step — it is reported once and never re-set")
    func freePersistsAcrossLaterStep() {
        let afterFree = SingingEngineInstallProgress.applying(
            .free(kb: 999_999), to: .init(stepName: "preflight", stepIndex: 1, stepCount: 9))
        #expect(afterFree.freeKB == 999_999)
        let afterLaterStep = SingingEngineInstallProgress.applying(
            .step(name: "finish", index: 9, count: 9), to: afterFree)
        #expect(afterLaterStep.freeKB == 999_999, "free space must still be the one preflight reported")
    }

    @Test(".skip sets stepSkipped and moves stepName/stepIndex, same as .step")
    func skipSetsStepSkipped() {
        let next = SingingEngineInstallProgress.applying(.skip(name: "uv"), to: nil)
        #expect(next.stepName == "uv")
        #expect(next.stepSkipped == true)
    }

    @Test("a fresh .step clears stepSkipped from a previous skip")
    func stepClearsSkippedFlag() {
        let afterSkip = SingingEngineInstallProgress.applying(.skip(name: "uv"), to: nil)
        let afterStep = SingingEngineInstallProgress.applying(
            .step(name: "python", index: 3, count: 9), to: afterSkip)
        #expect(afterStep.stepSkipped == false)
    }
}

// MARK: - The pure classifier

@Suite("SingingEngineInstaller.classify — exit code + @@ vocabulary together (item p2-sing-c)")
struct SingingEngineInstallerClassifyTests {
    @Test("exit 0 + a trailing .done -> .succeeded(bytes)")
    func exit0WithDoneSucceeds() {
        let outcome = SingingEngineInstaller.classify(
            exitCode: 0, lines: [.step(name: "finish", index: 9, count: 9), .done(installedBytes: 42)],
            stderrTail: "")
        #expect(outcome == .succeeded(installedBytes: 42))
    }

    @Test("exit 0 with NO .done at all -> .succeeded(nil), an honest anomaly, never a silent 0")
    func exit0WithoutDoneSucceedsWithNilBytes() {
        let outcome = SingingEngineInstaller.classify(exitCode: 0, lines: [], stderrTail: "")
        #expect(outcome == .succeeded(installedBytes: nil))
    }

    @Test("exit 1 + a trailing .error -> .failed(step, message)")
    func exit1WithErrorFails() {
        let outcome = SingingEngineInstaller.classify(
            exitCode: 1, lines: [.step(name: "voice", index: 8, count: 9), .error(step: "voice", message: "bad hash")],
            stderrTail: "")
        #expect(outcome == .failed(step: "voice", message: "bad hash"))
    }

    @Test("exit 1 with NO .error line -> .failed('unknown', stderr tail or a fallback message)")
    func exit1WithoutErrorFallsBackToStderr() {
        let outcome = SingingEngineInstaller.classify(exitCode: 1, lines: [], stderrTail: "something crashed")
        #expect(outcome == .failed(step: "unknown", message: "something crashed"))
    }

    @Test("exit 2 -> .badUsage(the last stderr line)")
    func exit2IsBadUsage() {
        let outcome = SingingEngineInstaller.classify(
            exitCode: 2, lines: [], stderrTail: "install.sh: SING_RUNTIME_DIR must be an absolute path")
        #expect(outcome == .badUsage(message: "install.sh: SING_RUNTIME_DIR must be an absolute path"))
    }

    @Test("exit 75 + .error naming a pid -> .alreadyRunning(pid:)")
    func exit75IsAlreadyRunningWithPid() {
        let outcome = SingingEngineInstaller.classify(
            exitCode: 75,
            lines: [.error(step: "preflight", message: "another install is running (pid 4242)")],
            stderrTail: "")
        #expect(outcome == .alreadyRunning(pid: 4242))
    }

    @Test("exit 143 + .cancelled -> .cancelled(step:)")
    func exit143IsCancelled() {
        let outcome = SingingEngineInstaller.classify(
            exitCode: 143, lines: [.cancelled(step: "weights")], stderrTail: "")
        #expect(outcome == .cancelled(step: "weights"))
    }

    @Test("exit 143 with NO .cancelled line -> .cancelled(nil), an honest anomaly")
    func exit143WithoutCancelledLineIsCancelledWithNilStep() {
        let outcome = SingingEngineInstaller.classify(exitCode: 143, lines: [], stderrTail: "")
        #expect(outcome == .cancelled(step: nil))
    }

    @Test("an undocumented exit code (137, a raw SIGKILL) -> .crashed, never forced into one of the five")
    func undocumentedExitCodeCrashes() {
        let outcome = SingingEngineInstaller.classify(exitCode: 137, lines: [], stderrTail: "killed")
        #expect(outcome == .crashed(exitCode: 137, stderrTail: "killed"))
    }

    @Test("a negative exit code (would never come from a real child, but classify stays total) -> .crashed")
    func negativeExitCodeCrashes() {
        let outcome = SingingEngineInstaller.classify(exitCode: -1, lines: [], stderrTail: "")
        #expect(outcome == .crashed(exitCode: -1, stderrTail: ""))
    }

    // MARK: FIX NOW #5 (architect review Q6) — `terminationReason == .uncaughtSignal` means
    // `exitCode` is actually a SIGNAL NUMBER, read before the exit-code switch above, never
    // folded into one of the five documented exit codes.

    @Test("uncaught SIGHUP (1), no cancel requested -> .crashed(1), never misread as exit code 1 (.failed)")
    func uncaughtSighupNeverMisreadsAsFailed() {
        let outcome = SingingEngineInstaller.classify(
            exitCode: SIGHUP, lines: [], stderrTail: "", terminationReason: .uncaughtSignal,
            cancelRequested: false)
        #expect(outcome == .crashed(exitCode: SIGHUP, stderrTail: ""))
    }

    @Test("uncaught SIGINT (2), no cancel requested -> .crashed(2), never misread as exit code 2 (.badUsage)")
    func uncaughtSigintWithoutCancelNeverMisreadsAsBadUsage() {
        let outcome = SingingEngineInstaller.classify(
            exitCode: SIGINT, lines: [], stderrTail: "", terminationReason: .uncaughtSignal,
            cancelRequested: false)
        #expect(outcome == .crashed(exitCode: SIGINT, stderrTail: ""))
    }

    @Test("uncaught SIGTERM (15), cancel WAS requested -> .cancelled(step: nil) -- the pre-trap-install window")
    func uncaughtSigtermWithCancelRequestedIsCancelled() {
        let outcome = SingingEngineInstaller.classify(
            exitCode: SIGTERM, lines: [], stderrTail: "", terminationReason: .uncaughtSignal,
            cancelRequested: true)
        #expect(outcome == .cancelled(step: nil))
    }

    @Test("uncaught SIGTERM (15), NO cancel requested -> .crashed(15), an external kill, not ours")
    func uncaughtSigtermWithoutCancelRequestedCrashes() {
        let outcome = SingingEngineInstaller.classify(
            exitCode: SIGTERM, lines: [], stderrTail: "", terminationReason: .uncaughtSignal,
            cancelRequested: false)
        #expect(outcome == .crashed(exitCode: SIGTERM, stderrTail: ""))
    }

    @Test("uncaught SIGINT (2), cancel WAS requested -> .cancelled(step: nil), same rule as SIGTERM")
    func uncaughtSigintWithCancelRequestedIsCancelled() {
        let outcome = SingingEngineInstaller.classify(
            exitCode: SIGINT, lines: [], stderrTail: "", terminationReason: .uncaughtSignal,
            cancelRequested: true)
        #expect(outcome == .cancelled(step: nil))
    }
}

// MARK: - Real install, against the local fixture mirror

@Suite("SingingEngineInstaller.install — real install.sh against the fixture mirror (item p2-sing-c)")
struct SingingEngineInstallerRealInstallTests {
    @Test(
        """
        a full install succeeds: .succeeded(bytes != nil), install.json exists, \
        the last progress tick is 'finish' 9/9, at least one .bytes tick names the 3 MiB fixture weights
        """,
        .enabled(if: SingingInstallerFixture.machineHasFixtureInputs))
    func fullInstallSucceeds() async throws {
        let fixture = try SingingInstallerFixture.requirePaths()
        let (runtimeDir, runtimeRoot) = try testRuntimeDir(tag: "A")
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }
        let installer = SingingEngineInstaller(configuration: .init(
            scriptsDir: try testScriptsDir(), runtimeDir: runtimeDir,
            installSource: fixture.mirror, pinsFile: fixture.pins))
        let collector = ProgressCollector()

        let outcome = await installer.install(progress: { collector.record($0) })

        guard case .succeeded(let bytes) = outcome else {
            Issue.record("expected .succeeded, got \(outcome)")
            return
        }
        #expect(bytes != nil)
        #expect(FileManager.default.fileExists(
            atPath: runtimeDir.appendingPathComponent("install.json").path))
        let ticks = collector.ticks
        #expect(!ticks.isEmpty)
        #expect(ticks.last?.stepName == "finish")
        #expect(ticks.last?.stepIndex == 9)
        // MEASURED directly (raw `bash install.sh` against this same fixture mirror, 2026-09-27):
        // "@@bytes 3145790 3145790" — 3,145,790, not exactly `3 << 20` (3,145,728): `hf_fetch.py`
        // reports the COMBINED total of model.pt (the pinned, exact 3 MiB) plus config.yaml (62
        // more bytes), not model.pt alone. Asserting a loose lower bound instead of the exact
        // figure: it is still unambiguously "the multi-megabyte weights download", without this
        // test being fragile to config.yaml's own byte count ever changing by a few bytes.
        #expect(ticks.contains { ($0.bytesTotal ?? 0) >= 3_000_000 }, "got bytesTotal values: \(ticks.map(\.bytesTotal))")
    }

    @Test(
        """
        a re-run of an already-installed runtime is idempotent: succeeds, every step after the \
        first reports stepSkipped
        """,
        .enabled(if: SingingInstallerFixture.machineHasFixtureInputs))
    func reRunIsIdempotent() async throws {
        let fixture = try SingingInstallerFixture.requirePaths()
        let (runtimeDir, runtimeRoot) = try testRuntimeDir(tag: "B")
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }
        let installer = SingingEngineInstaller(configuration: .init(
            scriptsDir: try testScriptsDir(), runtimeDir: runtimeDir,
            installSource: fixture.mirror, pinsFile: fixture.pins))

        let first = await installer.install(progress: { _ in })
        guard case .succeeded = first else {
            Issue.record("expected the FIRST install to succeed, got \(first)")
            return
        }

        let collector = ProgressCollector()
        let second = await installer.install(progress: { collector.record($0) })
        guard case .succeeded = second else {
            Issue.record("expected the RE-RUN to also succeed, got \(second)")
            return
        }
        let skipTicks = collector.ticks.filter { $0.stepSkipped }
        // 8 of 9 steps skip on a clean re-run (SB's own measured "8/8 @@skip" — "finish" makes 9
        // steps total, and finish's own re-verify still counts as unchanged, not a skip line).
        #expect(skipTicks.count == 8, "got skip ticks for: \(skipTicks.map(\.stepName))")
    }

    @Test(
        """
        cancelling mid-download: .cancelled(step: weights), nothing left that looks installed, \
        the download's own process leaves no trace
        """,
        .enabled(if: SingingInstallerFixture.machineHasFixtureInputs))
    func cancelMidDownloadLeavesNothingInstalled() async throws {
        let fixture = try SingingInstallerFixture.requirePaths()
        let (runtimeDir, runtimeRoot) = try testRuntimeDir(tag: "C")
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }
        let installer = SingingEngineInstaller(configuration: .init(
            scriptsDir: try testScriptsDir(), runtimeDir: runtimeDir,
            installSource: fixture.mirror, pinsFile: fixture.pins,
            // `test_install.py`'s own exact value — slow enough that a `@@bytes` tick reliably
            // lands (and this test can wait for it) before the whole 3 MiB fixture download would
            // otherwise finish in milliseconds.
            testExtraEnvironment: ["SING_FIXTURE_THROTTLE_S": "1.5"]))
        let collector = ProgressCollector()

        let installTask = Task { await installer.install(progress: { collector.record($0) }) }
        await collector.waitForFirstBytesTick()
        // Positive control: prove there really is something running against this runtime BEFORE
        // asking it to stop, so "nothing left afterward" means something.
        let before = Self.processesM(mentioning: runtimeDir.path)
        #expect(!before.isEmpty, "expected a live download process before cancelling, saw none")
        installTask.cancel()

        let outcome = await installTask.value
        guard case .cancelled(let step) = outcome else {
            Issue.record("expected .cancelled, got \(outcome)")
            return
        }
        #expect(step == "weights")
        #expect(!FileManager.default.fileExists(
            atPath: runtimeDir.appendingPathComponent("install.json").path))
        let staging = (try? FileManager.default.contentsOfDirectory(atPath: runtimeDir.path))?
            .filter { $0.hasPrefix(".staging-") } ?? []
        #expect(staging.isEmpty)
        let after = Self.processesM(mentioning: runtimeDir.path)
        #expect(after.isEmpty, "a process is still mentioning the runtime dir after cancel: \(after)")
    }

    @Test(
        """
        FIX NOW #5. A cancel requested BEFORE install.sh ever launches -> .cancelled(step: nil): \
        no progress ticks, no install.json, no staging, and an empty process census
        """,
        .enabled(if: SingingInstallerFixture.machineHasFixtureInputs))
    func cancelBeforeLaunchNeverSpawns() async throws {
        let fixture = try SingingInstallerFixture.requirePaths()
        let (runtimeDir, runtimeRoot) = try testRuntimeDir(tag: "G")
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }
        let installer = SingingEngineInstaller(configuration: .init(
            scriptsDir: try testScriptsDir(), runtimeDir: runtimeDir,
            installSource: fixture.mirror, pinsFile: fixture.pins))
        let collector = ProgressCollector()

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await installer.install(progress: { collector.record($0) })
        }
        let outcome = await task.value

        guard case .cancelled(let step) = outcome else {
            Issue.record("expected .cancelled, got \(outcome)")
            return
        }
        #expect(step == nil)
        #expect(collector.ticks.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: runtimeDir.appendingPathComponent("install.json").path))
        let staging = (try? FileManager.default.contentsOfDirectory(atPath: runtimeDir.path))?
            .filter { $0.hasPrefix(".staging-") } ?? []
        #expect(staging.isEmpty)
        let census = Self.processesM(mentioning: runtimeDir.path)
        #expect(census.isEmpty, "a process is mentioning the runtime dir despite a pre-launch cancel: \(census)")
    }

    private static func processesM(mentioning needle: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").map(String.init)
            .filter { $0.contains(needle) && !$0.contains("/bin/ps") }
    }
}

// MARK: - cannotLaunch / badUsage

@Suite("SingingEngineInstaller.install — cannotLaunch and badUsage (item p2-sing-c)")
struct SingingEngineInstallerFailureShapeTests {
    @Test("a nil scriptsDir -> .cannotLaunch, nothing spawned")
    func nilScriptsDirCannotLaunch() async throws {
        let (runtimeDir, runtimeRoot) = try testRuntimeDir(tag: "D")
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }
        let installer = SingingEngineInstaller(configuration: .init(
            scriptsDir: nil, runtimeDir: runtimeDir))
        let outcome = await installer.install(progress: { _ in })
        guard case .cannotLaunch = outcome else {
            Issue.record("expected .cannotLaunch, got \(outcome)")
            return
        }
    }

    @Test("installSource set without pinsFile (or vice versa) -> .cannotLaunch naming 'together'")
    func mismatchedFixturePairCannotLaunch() async throws {
        let (runtimeDir, runtimeRoot) = try testRuntimeDir(tag: "E")
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }
        let installer = SingingEngineInstaller(configuration: .init(
            scriptsDir: try testScriptsDir(), runtimeDir: runtimeDir,
            installSource: URL(fileURLWithPath: "/tmp/nonexistent-mirror"), pinsFile: nil))
        let outcome = await installer.install(progress: { _ in })
        guard case .cannotLaunch(let reason) = outcome else {
            Issue.record("expected .cannotLaunch, got \(outcome)")
            return
        }
        #expect(reason.contains("together"))
    }

    @Test(
        "a pins file with a line install.sh's own PIN_RE refuses -> exit 2, .badUsage naming 'not KEY=value'",
        .enabled(if: SingingInstallerFixture.machineHasFixtureInputs))
    func badPinsLineIsBadUsage() async throws {
        let fixture = try SingingInstallerFixture.requirePaths()
        let (runtimeDir, runtimeRoot) = try testRuntimeDir(tag: "F")
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }
        let badPins = runtimeDir.deletingLastPathComponent().appendingPathComponent("bad-pins.env")
        // A single line with '$' and '(' -- outside install.sh's PIN_RE character classes for an
        // unquoted value, so `load_pins` refuses it on line 1, before any real work.
        try Data("FOO=$(rm -rf)\n".utf8).write(to: badPins)

        let installer = SingingEngineInstaller(configuration: .init(
            scriptsDir: try testScriptsDir(), runtimeDir: runtimeDir,
            installSource: fixture.mirror, pinsFile: badPins))
        let outcome = await installer.install(progress: { _ in })
        guard case .badUsage(let message) = outcome else {
            Issue.record("expected .badUsage, got \(outcome)")
            return
        }
        #expect(message.contains("not KEY=value"), "got: \(message)")
    }
}
