import Darwin
import Foundation

/// One home (house "ONE home" rule) for the question *"which OS process is
/// actually serving this sidecar, and is it safe for us to signal it?"* —
/// m23-bb.
///
/// Before this existed, `SidecarManager.stop()` resolved its target from the
/// pidfile alone while `status()` resolved it from the health probe, so the
/// two disagreed about what "the sidecar" even is: with a stale pidfile and a
/// live sidecar on the port, `stop()` deleted the pidfile, reported *"was not
/// running (stale pidfile removed)"*, and left the sidecar running.
///
/// Everything here splits into a PURE half (parsing, tree walking) that is
/// directly unit-testable against a synthetic snapshot, and a thin impure half
/// (`captureSnapshot()`, `listeners(onPort:)`, `args(ofPid:)`) that shells out
/// to `/bin/ps` and `/usr/sbin/lsof`. Both are read-only: nothing in this file
/// ever signals a process.
enum SidecarProcessDiscovery {
    // MARK: - Pure: process table model

    /// One row of `ps -eo pid,ppid,args`.
    struct Entry: Sendable, Equatable {
        var pid: Int32
        var ppid: Int32
        var args: String

        init(pid: Int32, ppid: Int32, args: String) {
            self.pid = pid
            self.ppid = ppid
            self.args = args
        }
    }

    /// An immutable snapshot of the process table. Immutable ON PURPOSE: the
    /// parent/child linkage it records is destroyed the moment a signal lands
    /// — a child whose parent exits is reparented to pid 1, measured directly
    /// at m23-az-1 and re-confirmed for this item — so any descendant set must
    /// be captured BEFORE signalling and then consulted, never re-derived
    /// after.
    struct Snapshot: Sendable, Equatable {
        var entries: [Entry]

        init(entries: [Entry] = []) {
            self.entries = entries
        }

        /// Guard rails against a malformed/cyclic `ppid` chain (which `ps`
        /// should never produce, but a walk that trusts it can hang).
        private static let maxWalkDepth = 64

        func entry(pid: Int32) -> Entry? {
            entries.first { $0.pid == pid }
        }

        /// The command line of `pid`, or nil when this snapshot has no row for
        /// it (process exited, or started after the snapshot was taken).
        /// Callers must treat nil as *unknown*, never as *not ours*.
        func args(of pid: Int32) -> String? {
            entry(pid: pid)?.args
        }

        func children(of pid: Int32) -> [Entry] {
            entries.filter { $0.ppid == pid && $0.pid != pid }
        }

        /// Every transitive descendant of `pid` (excluding `pid` itself), in
        /// breadth-first order. This is the set that must be accounted for
        /// when the sidecar is stopped: m23-bb's own report records the
        /// topology as `pid 49156 -> python 49160 listening on 8001`, and the
        /// CHILD is what holds the ~75 GB.
        func descendants(of pid: Int32) -> [Entry] {
            var found: [Entry] = []
            var seen: Set<Int32> = [pid]
            var frontier: [Int32] = [pid]
            var depth = 0
            while !frontier.isEmpty, depth < Self.maxWalkDepth {
                var next: [Int32] = []
                for parent in frontier {
                    for child in children(of: parent) where !seen.contains(child.pid) {
                        seen.insert(child.pid)
                        found.append(child)
                        next.append(child.pid)
                    }
                }
                frontier = next
                depth += 1
            }
            return found
        }

        /// The `ppid` chain above `pid`, nearest first, stopping at pid 1 /
        /// pid 0 (both excluded — nothing here may ever target them).
        func ancestors(of pid: Int32) -> [Int32] {
            var found: [Int32] = []
            var seen: Set<Int32> = [pid]
            var current = pid
            var depth = 0
            while depth < Self.maxWalkDepth {
                guard let entry = entry(pid: current) else { break }
                let parent = entry.ppid
                guard parent > 1, !seen.contains(parent) else { break }
                found.append(parent)
                seen.insert(parent)
                current = parent
                depth += 1
            }
            return found
        }

        /// Walks UP from `pid` while the parent still satisfies `matches`,
        /// returning the topmost such process (or `pid` itself when the parent
        /// doesn't match).
        ///
        /// Why this exists: port discovery finds the process HOLDING THE
        /// LISTENING SOCKET, which for ACE-Step is the python CHILD, not the
        /// `uv run` parent that supervises it. Killing only the child leaves
        /// the supervisor behind. Climbing to the topmost process that still
        /// identifies as the sidecar makes the subsequent descendant capture
        /// cover the whole tree.
        ///
        /// `blocked` is a hard stop, not a preference: it carries this
        /// process and its own ancestors, so a checkout path that happens to
        /// contain "ace-step" can never let the climb walk into DAW Pro
        /// itself.
        func climb(
            from pid: Int32, blocked: Set<Int32>, matches: (Entry) -> Bool
        ) -> Int32 {
            var current = pid
            var seen: Set<Int32> = [pid]
            var depth = 0
            while depth < Self.maxWalkDepth {
                guard let entry = entry(pid: current) else { return current }
                let parentPid = entry.ppid
                guard parentPid > 1, !seen.contains(parentPid), !blocked.contains(parentPid),
                      let parent = self.entry(pid: parentPid), matches(parent)
                else {
                    return current
                }
                seen.insert(parentPid)
                current = parentPid
                depth += 1
            }
            return current
        }
    }

    /// Pure parser for `ps -eo pid,ppid,args` output. Skips the header and any
    /// row without all three fields (kernel threads can report empty args).
    static func parseSnapshot(psOutput: String) -> Snapshot {
        var entries: [Entry] = []
        for line in psOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1])
            else { continue }
            entries.append(Entry(pid: pid, ppid: ppid, args: String(fields[2])))
        }
        return Snapshot(entries: entries)
    }

    // MARK: - Pure: port lookup result

    /// The three outcomes of asking "who is listening on this port?", kept
    /// distinct because they need DIFFERENT messages: "nothing is listening"
    /// and "I could not ask" are not the same answer, and collapsing them is
    /// how a check starts passing vacuously (the m23-az-1 lesson).
    enum PortLookup: Sendable, Equatable {
        case listeners([Int32])
        case nothingListening
        case unavailable(String)
    }

    /// Pure parser for `lsof -t` output (one pid per line).
    static func parseListenerPids(lsofOutput: String) -> [Int32] {
        var pids: [Int32] = []
        for line in lsofOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid > 0 else { continue }
            if !pids.contains(pid) { pids.append(pid) }
        }
        return pids.sorted()
    }

    /// Pure: the TCP port a sidecar base URL actually serves. Never hardcoded
    /// — 8001 (ACE-Step) and 8002 (RVC) both come through here, and tests
    /// point at ephemeral ports.
    static func port(of baseURL: URL) -> UInt16? {
        if let port = baseURL.port, port > 0, port <= Int(UInt16.max) {
            return UInt16(port)
        }
        switch baseURL.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    // MARK: - Impure: reading the live system (read-only)

    private static let psPath = "/bin/ps"
    private static let lsofPath = "/usr/sbin/lsof"

    /// `ps -eo pid,ppid,args`. Returns an EMPTY snapshot (never nil) when `ps`
    /// can't be run, so callers get "unknown" rather than a crash — and every
    /// caller is written to treat unknown as unknown.
    static func captureSnapshot() -> Snapshot {
        switch runCapturingOutput(psPath, ["-Awwo", "pid,ppid,args"]) {
        case .success(let output): return parseSnapshot(psOutput: output)
        case .failure: return Snapshot()
        }
    }

    /// The command line of a single live pid, or nil when it can't be read
    /// (process gone, or `ps` unavailable). `-ww` defeats `ps`'s default
    /// column truncation, which would otherwise make two different command
    /// lines compare equal.
    static func args(ofPid pid: Int32) -> String? {
        guard case .success(let output) = runCapturingOutput(psPath, ["-ww", "-p", "\(pid)", "-o", "args="])
        else { return nil }
        let trimmed = output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Who holds the LISTENING socket on `port` (loopback or otherwise).
    /// `lsof` exits 1 with no output when nothing matches, which is
    /// `.nothingListening` — distinct from `.unavailable`, which means we
    /// never got to ask.
    static func listeners(onPort port: UInt16) -> PortLookup {
        guard FileManager.default.isExecutableFile(atPath: lsofPath) else {
            return .unavailable("\(lsofPath) is not available on this system")
        }
        switch runCapturingOutput(lsofPath, ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]) {
        case .failure(let detail):
            return .unavailable(detail)
        case .success(let output):
            let pids = parseListenerPids(lsofOutput: output)
            return pids.isEmpty ? .nothingListening : .listeners(pids)
        }
    }

    /// Outcome of a read-only helper invocation: its stdout, or why it could
    /// not be run at all (which is NOT the same as "it found nothing").
    enum HelperOutput: Sendable, Equatable {
        case success(String)
        case failure(String)
    }

    /// Runs a read-only helper and captures stdout. stdout is drained BEFORE
    /// `waitUntilExit()` — the reverse order deadlocks on any output larger
    /// than the pipe buffer, which a full `ps -A` listing comfortably exceeds.
    private static func runCapturingOutput(
        _ executablePath: String, _ arguments: [String]
    ) -> HelperOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failure("could not run \(executablePath): \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return .success(String(data: data, encoding: .utf8) ?? "")
    }
}
