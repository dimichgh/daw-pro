import Foundation

/// THE ONE HOME for "is this process a Swift test runner rather than the
/// shipped app" (m23-aa, promoted out of `ProjectStore` at m23-at).
///
/// It started life as `ProjectStore.isSwiftTestProcess` because the autosave
/// redirection was the only consumer. `DAWEngine` then needed the same
/// question for `AUHostRegistry.defaultPrepareTimeout`, and it could not see
/// an internal member of another module — the choice was a second copy or a
/// promotion. A second copy of a process-shape predicate is exactly the
/// divergence the one-home rule exists to prevent (two detectors that must
/// agree about the same process and are not made to), so this MOVED here. No
/// forwarder was left behind on purpose: two spellings of one predicate is the
/// bug, not the fix.
///
/// Nothing in this enum is a policy decision. It answers a factual question
/// about the running process; what to DO about the answer belongs to each
/// consumer, next to the value that diverges.
public enum TestEnvironment {

    /// True when THIS process is a Swift test runner rather than the shipped
    /// app. A pure function of injected process facts — never reads
    /// `ProcessInfo`/`CommandLine` itself — so both branches are unit-testable
    /// without actually swapping processes.
    ///
    /// Any one signal is sufficient, and none of them can occur in the shipped
    /// app's process: `swiftpm-testing-helper` is the dedicated harness binary
    /// `swift test --disable-xctest` launches (confirmed empirically — this
    /// project's own `./scripts/test.sh` runs exactly that shape); an `.xctest`
    /// bundle path in argv is the Xcode/plain-XCTest launch shape; and
    /// `--testing-library` is a flag `swift test` always passes through to the
    /// test binary regardless of which testing library ran.
    nonisolated public static func isSwiftTestProcess(processName: String,
                                                      arguments: [String]) -> Bool {
        if processName == "swiftpm-testing-helper" { return true }
        if arguments.contains("--testing-library") { return true }
        return arguments.contains { $0.contains(".xctest") }
    }

    /// The predicate applied to the REAL process, decided once per process.
    ///
    /// A `static let` rather than a computed property on purpose: the answer
    /// cannot change while the process runs, every consumer must get the same
    /// answer, and consumers read it from default-argument position where a
    /// re-scan of `CommandLine.arguments` would be silly.
    nonisolated public static let isRunningTests: Bool = isSwiftTestProcess(
        processName: ProcessInfo.processInfo.processName,
        arguments: CommandLine.arguments)
}
