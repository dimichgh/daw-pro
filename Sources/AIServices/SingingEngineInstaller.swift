import Foundation
import os

// MARK: - Progress

/// One accumulated snapshot of `scripts/sing/install.sh`'s `@@`-line stream (design
/// `docs/design/2026-09-27-p2-sing-integration.md` §2.5 "Progress"). Each field is the LATEST
/// value seen for that axis: a `@@bytes` line updates only the byte fields, `@@free` is reported
/// once at preflight and then simply persists (nothing ever un-sets it), `@@step`/`@@skip` both
/// move `stepName`/`stepIndex` and reset the byte fields to `nil` (a new step's bytes have not
/// been reported yet — carrying the PREVIOUS step's download fraction into a step that never
/// downloads anything would be exactly the "secondInstallDoesNotInheritStaleProgress" trap
/// `WhisperModelInstallCoordinator` already guards against, restated at the per-step grain here).
public struct SingingEngineInstallProgress: Sendable, Equatable, Codable {
    public var stepName: String
    public var stepIndex: Int
    public var stepCount: Int
    /// True on the tick that reported this step as `@@skip` rather than `@@step` — an idempotent
    /// re-run reports every already-verified step this way; a UI can grey a skipped step instead
    /// of animating a bar that will never move for it.
    public var stepSkipped: Bool
    public var bytesDone: Int64?
    public var bytesTotal: Int64?
    /// Free disk space at preflight, KB — reported once, near the very start, and kept thereafter.
    public var freeKB: Int64?

    public init(
        stepName: String, stepIndex: Int, stepCount: Int, stepSkipped: Bool = false,
        bytesDone: Int64? = nil, bytesTotal: Int64? = nil, freeKB: Int64? = nil
    ) {
        self.stepName = stepName
        self.stepIndex = stepIndex
        self.stepCount = stepCount
        self.stepSkipped = stepSkipped
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.freeKB = freeKB
    }
}

// MARK: - The pure line grammar

/// One parsed line of install.sh's stdout (its doc comment's own table, verbatim):
/// `@@step <name> <i>/<n>`, `@@skip <name>`, `@@bytes <done> <total>`, `@@free <kb>`,
/// `@@error <name> <message>`, `@@cancelled <name>`, `@@done <installedBytes>`. Everything else on
/// stdout is NOT this channel (human text goes to stderr, per the script's own `emit`/`say` split)
/// and `parse` returns `nil` for it — a caller that only ever calls `parse` on lines already
/// filtered to a `"@@"` prefix will never see `nil`; `SingingEngineInstaller`'s reader does that
/// filtering, but `parse` stays total (never traps) for anything handed to it directly, which is
/// what makes it independently unit-testable against install.sh's doc comment line-for-line.
enum SingingEngineInstallLine: Sendable, Equatable {
    case step(name: String, index: Int, count: Int)
    case skip(name: String)
    case bytes(done: Int64, total: Int64)
    case free(kb: Int64)
    case error(step: String, message: String)
    case cancelled(step: String)
    case done(installedBytes: Int64)

    /// PURE — no I/O. `line` is one already-`@@`-prefixed line, without its trailing newline.
    static func parse(_ line: String) -> SingingEngineInstallLine? {
        guard line.hasPrefix("@@") else { return nil }
        let body = line.dropFirst(2)
        guard let space = body.firstIndex(of: " ") else { return nil }
        let tag = body[body.startIndex..<space]
        let rest = body[body.index(after: space)...]
        switch tag {
        case "step":
            // "<name> <i>/<n>"
            let parts = rest.split(separator: " ")
            guard parts.count == 2, let slash = parts[1].firstIndex(of: "/"),
                  let i = Int(parts[1][parts[1].startIndex..<slash]),
                  let n = Int(parts[1][parts[1].index(after: slash)...])
            else { return nil }
            return .step(name: String(parts[0]), index: i, count: n)
        case "skip":
            let name = rest.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return .skip(name: name)
        case "bytes":
            let parts = rest.split(separator: " ")
            guard parts.count == 2, let done = Int64(parts[0]), let total = Int64(parts[1])
            else { return nil }
            return .bytes(done: done, total: total)
        case "free":
            guard let kb = Int64(rest.trimmingCharacters(in: .whitespaces)) else { return nil }
            return .free(kb: kb)
        case "error":
            // "<name> <free-form message, may itself contain spaces>"
            guard let messageSpace = rest.firstIndex(of: " ") else { return nil }
            let name = String(rest[rest.startIndex..<messageSpace])
            let message = String(rest[rest.index(after: messageSpace)...])
            guard !name.isEmpty, !message.isEmpty else { return nil }
            return .error(step: name, message: message)
        case "cancelled":
            let name = rest.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return .cancelled(step: name)
        case "done":
            guard let bytes = Int64(rest.trimmingCharacters(in: .whitespaces)) else { return nil }
            return .done(installedBytes: bytes)
        default:
            return nil
        }
    }

    /// The pid named in an `alreadyRunning`-shaped `@@error` message — `"another install is
    /// running (pid 12345)"` — install.sh's ONE literal wording (`install.sh` line ~146). `nil`
    /// if the message does not have that shape (defensive: a caller must not assume it always
    /// will, e.g. if this script's wording ever changes).
    static func pid(inAlreadyRunningMessage message: String) -> Int32? {
        guard let openParen = message.range(of: "(pid "),
              let closeParen = message.range(of: ")", range: openParen.upperBound..<message.endIndex)
        else { return nil }
        return Int32(message[openParen.upperBound..<closeParen.lowerBound])
    }
}

extension SingingEngineInstallProgress {
    /// PURE. Folds one parsed line into the running snapshot. `previous == nil` means "nothing has
    /// ticked yet" (before the first `@@step`), in which case a line that is not itself a
    /// `.step`/`.skip` is folded onto a synthetic all-zero starting point rather than crashing —
    /// install.sh always emits `@@step preflight 1/9` before anything else, so this path is not
    /// expected to matter in practice, but `apply` stays total either way.
    static func applying(_ line: SingingEngineInstallLine, to previous: SingingEngineInstallProgress?)
        -> SingingEngineInstallProgress {
        var progress = previous ?? SingingEngineInstallProgress(stepName: "", stepIndex: 0, stepCount: 0)
        switch line {
        case .step(let name, let index, let count):
            progress.stepName = name
            progress.stepIndex = index
            progress.stepCount = count
            progress.stepSkipped = false
            progress.bytesDone = nil
            progress.bytesTotal = nil
        case .skip(let name):
            progress.stepName = name
            progress.stepSkipped = true
            progress.bytesDone = nil
            progress.bytesTotal = nil
        case .bytes(let done, let total):
            progress.bytesDone = done
            progress.bytesTotal = total
        case .free(let kb):
            progress.freeKB = kb
        case .error, .cancelled, .done:
            // Terminal lines carry no NEW progress axis of their own — `SingingEngineInstallOutcome`
            // is what a caller reads for those, not this struct's last snapshot.
            break
        }
        return progress
    }
}

// MARK: - Outcome

/// What one `install.sh` run did, classified from its exit code AND its own documented `@@`
/// vocabulary together — never the exit code alone, because two of its five documented codes
/// (0 and 1) are meaningless without the line that explains them, and the classification stays
/// honest about the two cases that are not in that documented set at all
/// (`cannotLaunch`/`crashed`) rather than forcing them into one of the five.
public enum SingingEngineInstallOutcome: Sendable, Equatable {
    /// Exit 0. `installedBytes` is `nil` only if `@@done` was somehow never seen despite a clean
    /// exit — install.sh's own contract guarantees it always is, so a `nil` here is a real anomaly
    /// worth a reviewer's attention, not a value to hide behind a fallback of `0`.
    case succeeded(installedBytes: Int64?)
    /// Exit 1 — `fail()`'s own doc: every exit-1 path emits exactly one `@@error <step> <message>`
    /// first. `message` is install.sh's own wording, already teaching (e.g. the voice-rebuild
    /// message explains whether only the header or the samples differ).
    case failed(step: String, message: String)
    /// Exit 75 — another install.sh is already running. `pid`, when parseable, is that process's.
    case alreadyRunning(pid: Int32?)
    /// Exit 2 — bad usage/config, caught before anything ran. install.sh's `usage_fail` never
    /// emits an `@@error` line (only `fail()` does), so `message` comes from stderr.
    case badUsage(message: String)
    /// Exit 143 — SIGTERM/SIGINT was delivered (from `cancel()` below, or an external signal) and
    /// install.sh's own trap ran to completion: staging removed, `@@cancelled <step>` was the
    /// last line. `step` is `nil` only if that line was somehow never seen despite the documented
    /// exit code — again a real anomaly, not something to paper over.
    case cancelled(step: String?)
    /// An exit code install.sh's own contract does not document (only 0/1/2/75/143 are) — e.g. a
    /// raw signal death from something other than this type's own SIGTERM-on-cancel path, or a
    /// bash-internal failure before the trap could even install itself.
    case crashed(exitCode: Int32, stderrTail: String)
    /// install.sh itself (or the `scriptsDir` that should contain it) could not be found, so
    /// nothing was ever launched — an app-packaging problem, not an install-time failure. Mirrors
    /// `SidecarError.notInstalled`'s wording style on purpose (same class of problem).
    case cannotLaunch(reason: String)
}

// MARK: - The installer

/// Runs `scripts/sing/install.sh` and turns its `@@`-line stdout stream into
/// `SingingEngineInstallProgress` ticks plus a final `SingingEngineInstallOutcome` (item
/// p2-sing-c). A plain, stateless `Sendable` struct — like `SoundBankInstaller` and
/// `WhisperModelInstaller`, it does its own one-shot job with no isolation of its own;
/// `SingingEngineInstallCoordinator` is what sequences calls to it and remembers the result for a
/// poller. See that type's doc for why a coordinator exists at all.
///
/// ## Why `install` never throws
///
/// `WhisperModelInstaller.install`/`SoundBankInstaller.install` are `async throws` because their
/// domain has exactly two shapes: it worked, or one exception explains why not. install.sh's
/// domain is richer — FIVE documented exit codes, two of which (0 and 1) are meaningless without
/// the `@@` line that explains them — so `SingingEngineInstallOutcome` already IS the "what
/// happened" answer for every shape, expected or not (including the two undocumented-by-the-script
/// shapes, `cannotLaunch`/`crashed`). Adding `throws` on top would just mean deciding, arbitrarily,
/// which of seven outcomes gets to skip the enum and become a thrown error instead — a distinction
/// with no caller who needs it. `SingingEngineInstallCoordinator.finish` reads this enum directly,
/// so its own `Task` body needs no `do`/`catch` either. **This is a deliberate difference from the
/// Whisper/SoundBank precedent, not an oversight — flagged for review.**
///
/// ## Cancellation
///
/// There is no cancel PARAMETER — the standard Swift idiom applies instead:
/// `withTaskCancellationHandler` wraps the wait for the child's exit, so cancelling the `Task` this
/// call runs in (which is exactly what `SingingEngineInstallCoordinator.cancel()` does, the
/// `SoundBankDownloadCoordinator` precedent) fires `process.terminate()` — a real SIGTERM to
/// install.sh — IMMEDIATELY, regardless of whether the process happens to be mid-write to a pipe
/// at that moment. install.sh's own trap then does the real work (kills the running step's whole
/// process group, removes staging, emits `@@cancelled <step>`, exits 143); this type only ever
/// reports what already happened, the same "status races the filesystem" rule
/// `SoundBankDownloadCoordinator.cancel`'s doc states for its own transfer.
///
/// ## Why a `Process`, unlike Whisper/SoundBank's `URLSession`
///
/// A plain `Task.cancel()` does nothing to an OS process — Swift's cooperative cancellation only
/// reaches APIs that themselves check `Task.isCancelled` at their own suspension points (which is
/// exactly what makes `URLSession`'s async methods "just work" for those two precedents).
/// `withTaskCancellationHandler`'s `onCancel` closure is the documented bridge for exactly this
/// case — a non-cooperative external resource — and runs synchronously the instant cancellation is
/// requested, not on the next suspension point, so it is not vulnerable to the "no `@@` line
/// arrives for a while during `venv`'s pip install" latency a naive "poll `Task.isCancelled` between
/// reads" loop would have.
public struct SingingEngineInstaller: Sendable {

    public struct Configuration: Sendable {
        /// Where `install.sh` (and `pins.env`, `requirements.lock`, `tools/`) live.
        public var scriptsDir: URL?
        /// Where the engine gets installed — `SING_RUNTIME_DIR`.
        public var runtimeDir: URL?
        /// TEST ONLY: `SING_INSTALL_SOURCE` — a local fixture mirror. Must travel with `pinsFile`
        /// or neither (install.sh's own rule; `install()` refuses the mismatched-pair case itself
        /// rather than letting install.sh's `usage_fail` explain it least legibly).
        public var installSource: URL?
        /// TEST ONLY: `SING_PINS_FILE`.
        public var pinsFile: URL?
        /// TEST-ONLY passthrough, merged onto the child's environment LAST — e.g.
        /// `SING_FIXTURE_THROTTLE_S` for a cancel test. Production code must never populate this.
        public var testExtraEnvironment: [String: String]

        public init(
            scriptsDir: URL?, runtimeDir: URL?, installSource: URL? = nil, pinsFile: URL? = nil,
            testExtraEnvironment: [String: String] = [:]
        ) {
            self.scriptsDir = scriptsDir
            self.runtimeDir = runtimeDir
            self.installSource = installSource
            self.pinsFile = pinsFile
            self.testExtraEnvironment = testExtraEnvironment
        }

        /// `DAWPRO_SING_SCRIPTS_DIR`/`DAWPRO_SING_RUNTIME_DIR` resolution is shared verbatim with
        /// `SingingSidecarManager.Configuration` — both need "the same scripts, the same profile's
        /// runtime folder", and keeping one resolver means the two can never quietly disagree about
        /// where either lives.
        public static func resolved(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Configuration {
            Configuration(
                scriptsDir: SingingSidecarManager.Configuration.resolveScriptsDir(environment: environment),
                runtimeDir: SingingSidecarManager.Configuration.resolveRuntimeDir(environment: environment))
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration = .resolved()) {
        self.configuration = configuration
    }

    /// Runs install.sh to completion (or until cancelled) and returns what happened. `progress` is
    /// called synchronously, from an arbitrary background thread (`Pipe`'s own readability-handler
    /// thread — never this call's own `Task`), once per parsed `@@` line, in the order the lines
    /// arrived — the `WhisperModelInstallCoordinator`/`SoundBankDownloadCoordinator` "why progress
    /// does not go through the actor's mailbox" reasoning, restated: routing each tick through an
    /// actor hop would risk two ticks landing out of order with no ordering guarantee between the
    /// unstructured tasks that would carry them.
    public func install(
        progress: @escaping @Sendable (SingingEngineInstallProgress) -> Void
    ) async -> SingingEngineInstallOutcome {
        guard let scriptsDir = configuration.scriptsDir else {
            return .cannotLaunch(
                reason: "the singing engine's install script could not be found — set "
                    + "DAWPRO_SING_SCRIPTS_DIR, or run the app from inside the daw-pro repo "
                    + "checkout (expects scripts/sing/install.sh).")
        }
        let installScript = scriptsDir.appendingPathComponent("install.sh")
        guard FileManager.default.fileExists(atPath: installScript.path) else {
            return .cannotLaunch(reason: "install.sh not found at \(installScript.path).")
        }
        guard let runtimeDir = configuration.runtimeDir else {
            return .cannotLaunch(reason: "the singing engine's runtime directory could not be resolved.")
        }
        if (configuration.installSource == nil) != (configuration.pinsFile == nil) {
            return .cannotLaunch(
                reason: "installSource and pinsFile are test-only and must be set together, or "
                    + "neither — install.sh refuses this pairing itself, but less legibly.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [installScript.path]
        process.currentDirectoryURL = scriptsDir
        process.environment = childEnvironment(base: ProcessInfo.processInfo.environment, runtimeDir: runtimeDir)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let progressBox = OSAllocatedUnfairLock<SingingEngineInstallProgress?>(initialState: nil)
        let atLinesBox = OSAllocatedUnfairLock<[SingingEngineInstallLine]>(initialState: [])
        let stderrTailBox = OSAllocatedUnfairLock<String>(initialState: "")
        // Boxed, not plain captured `var`s: `readabilityHandler` runs on `Pipe`'s own dispatch
        // source, a DIFFERENT execution context from this `async` call's body, so Swift 6 refuses
        // a captured mutable var here outright (#SendableClosureCaptures) — correctly, since stdout
        // and stderr's two handlers can themselves fire concurrently with one another.
        let stdoutRemainderBox = OSAllocatedUnfairLock<Data>(initialState: Data())
        let stderrRemainderBox = OSAllocatedUnfairLock<Data>(initialState: Data())

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }   // EOF sentinel — nothing left to flush (lines are '\n'-terminated)
            let parsedLines: [SingingEngineInstallLine] = stdoutRemainderBox.withLock { remainder in
                remainder.append(data)
                var found: [SingingEngineInstallLine] = []
                while let newline = remainder.firstIndex(of: 0x0A) {
                    let lineData = remainder[remainder.startIndex..<newline]
                    remainder.removeSubrange(remainder.startIndex...newline)
                    guard let line = String(data: lineData, encoding: .utf8), line.hasPrefix("@@"),
                          let parsed = SingingEngineInstallLine.parse(line)
                    else { continue }
                    found.append(parsed)
                }
                return found
            }
            for parsed in parsedLines {
                atLinesBox.withLock { $0.append(parsed) }
                // `.error`/`.cancelled`/`.done` never change a SINGLE field
                // `SingingEngineInstallProgress.applying` tracks (see its own doc: "terminal lines
                // carry no NEW progress axis of their own") — that information belongs in
                // `SingingEngineInstallOutcome`, read once from `classify` after this loop ends,
                // not repeated here as a progress tick that looks like something changed when
                // nothing did. Calling `progress` for them anyway produced an observed duplicate
                // (a `.skip`-shaped tick, unchanged, re-delivered the instant `.done` arrived) —
                // caught by `SingingEngineInstallerTests`' re-run test, not assumed away.
                switch parsed {
                case .error, .cancelled, .done:
                    continue
                case .step, .skip, .bytes, .free:
                    break
                }
                let updated = progressBox.withLock { box -> SingingEngineInstallProgress in
                    let next = SingingEngineInstallProgress.applying(parsed, to: box)
                    box = next
                    return next
                }
                progress(updated)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // Keep only the tail — install.sh's `say()` output over a 15-minute run could be long,
            // and only the last message (or a handful) is ever what a `badUsage`/`crashed` outcome
            // needs to explain itself.
            let maxBytes = 8192
            let text: String = stderrRemainderBox.withLock { remainder in
                remainder.append(data)
                if remainder.count > maxBytes {
                    remainder.removeFirst(remainder.count - maxBytes)
                }
                return String(data: remainder, encoding: .utf8) ?? ""
            }
            stderrTailBox.withLock { $0 = text }
        }

        let exitCode: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
                process.terminationHandler = { p in continuation.resume(returning: p.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    // `terminationHandler` was already assigned but the process never started, so
                    // it will never fire on its own — resume here, once, with a sentinel outside
                    // every real exit code install.sh (0/1/2/75/143) or a raw signal death could
                    // ever produce.
                    continuation.resume(returning: Int32.min)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()

        if exitCode == Int32.min {
            let tail = stderrTailBox.withLock { $0 }
            return .cannotLaunch(
                reason: tail.isEmpty ? "install.sh could not be launched." : tail)
        }
        return Self.classify(
            exitCode: exitCode, lines: atLinesBox.withLock { $0 },
            stderrTail: stderrTailBox.withLock { $0 })
    }

    /// PURE. The exit-code-plus-`@@`-vocabulary classification the type doc promises.
    static func classify(
        exitCode: Int32, lines: [SingingEngineInstallLine], stderrTail: String
    ) -> SingingEngineInstallOutcome {
        func lastError() -> (step: String, message: String)? {
            for line in lines.reversed() {
                if case .error(let step, let message) = line { return (step, message) }
            }
            return nil
        }
        let trimmedStderrTail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        switch exitCode {
        case 0:
            for line in lines.reversed() {
                if case .done(let bytes) = line { return .succeeded(installedBytes: bytes) }
            }
            return .succeeded(installedBytes: nil)
        case 1:
            if let (step, message) = lastError() { return .failed(step: step, message: message) }
            return .failed(
                step: "unknown",
                message: trimmedStderrTail.isEmpty
                    ? "install.sh exited 1 with no @@error line." : trimmedStderrTail)
        case 2:
            let lastStderrLine = trimmedStderrTail.split(separator: "\n").last.map(String.init)
            return .badUsage(
                message: lastStderrLine
                    ?? "install.sh exited 2 (bad usage/config) with no stderr captured.")
        case 75:
            if let (_, message) = lastError() {
                return .alreadyRunning(pid: SingingEngineInstallLine.pid(inAlreadyRunningMessage: message))
            }
            return .alreadyRunning(pid: nil)
        case 143:
            for line in lines.reversed() {
                if case .cancelled(let step) = line { return .cancelled(step: step) }
            }
            return .cancelled(step: nil)
        default:
            return .crashed(exitCode: exitCode, stderrTail: trimmedStderrTail)
        }
    }

    /// PURE. install.sh sets its own hermetic environment internally (unsets `PYTHONPATH`/
    /// `PYTHONHOME`, redirects every cache, scopes `uv`/git/huggingface_hub config to itself — see
    /// its own header comment) exactly like `run.sh` does, so this is a SMALL prepend, the
    /// `SingingSidecarManager.Configuration.childEnvironment` pattern restated: base first (PATH,
    /// HOME, and anything install.sh's own `ffmpeg`-discovery fallback chain or `/usr/bin/*` tools
    /// need), then the few keys install.sh actually reads from its caller, then test-only extras
    /// last so a test can always win.
    func childEnvironment(base: [String: String], runtimeDir: URL) -> [String: String] {
        var environment = base
        environment["SING_RUNTIME_DIR"] = runtimeDir.path
        if let installSource = configuration.installSource {
            environment["SING_INSTALL_SOURCE"] = installSource.path
        }
        if let pinsFile = configuration.pinsFile {
            environment["SING_PINS_FILE"] = pinsFile.path
        }
        for (key, value) in configuration.testExtraEnvironment { environment[key] = value }
        return environment
    }
}
