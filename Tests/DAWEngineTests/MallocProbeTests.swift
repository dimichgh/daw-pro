import Darwin
import Foundation
import Testing

/// m39-test-mallocprobe: two malloc measurements that overlap in time must each keep their OWN count.
///
/// `malloc_logger` is one process-wide slot, and 17 test files used to save and restore it independently. These
/// tests overlap two measurements on purpose, with semaphores rather than sleeps deciding the order, so the loss is
/// reproduced every run instead of once in a 2,306-test run.
@Suite("MallocProbe: overlapping measurements keep their own counts")
struct MallocProbeTests {
    /// One fixed burst of allocations. Returns the number of arrays kept alive so nothing is optimised away.
    @inline(never)
    private static func burst(_ count: Int) -> Int {
        var sink: [[Int]] = []
        var index = 0
        while index < count {
            sink.append([Int](repeating: index, count: 64))
            index += 1
        }
        return sink.count
    }

    private static let burstSize = 200

    /// A thread whose result is read after `join`.
    private final class Worker: @unchecked Sendable {
        private(set) var result: Int?
        private let done = DispatchSemaphore(value: 0)
        private nonisolated(unsafe) let work: () -> Int?
        init(_ work: @escaping () -> Int?) {
            self.work = work
            let thread = Thread { [self] in
                result = self.work()
                done.signal()
            }
            thread.start()
        }
        func join() -> Bool { done.wait(timeout: .now() + 20) == .success }
    }

    @Test("control: a solo measurement counts a burst, and the probe is not a stub")
    func soloMeasurementCounts() throws {
        let slot = try #require(MallocProbe.slot(), "malloc_logger is unavailable: FAILURE, not a skip")
        var kept = 0
        let solo = MallocProbe.events(slot: slot) { kept = Self.burst(Self.burstSize) }
        #expect(kept == Self.burstSize)
        #expect(solo >= Self.burstSize, "a \(Self.burstSize)-array burst counted only \(solo) events")
        // Zero is also reachable: an empty body counts nothing.
        let empty = MallocProbe.events(slot: slot) {}
        #expect(empty == 0, "an empty window counted \(empty)")
    }

    @Test("two measurements that overlap in time each keep every one of their events")
    func overlappingMeasurementsKeepTheirCounts() throws {
        let slot = try #require(MallocProbe.slot(), "malloc_logger is unavailable: FAILURE, not a skip")
        // The yardstick: what one burst counts when nothing overlaps it.
        // Separately measured bursts drift by a couple of events (first-call lazy allocations: MEASURED 416, 416, 418
        // on identical code), so take the MIN of several and allow a stated slack. Losing counts to an overlap looks
        // like 440 of 832 or 0, hundreds of events away from the slack.
        var one = Int.max
        var repeatIndex = 0
        while repeatIndex < 5 {
            one = min(one, MallocProbe.events(slot: slot) { _ = Self.burst(Self.burstSize) })
            repeatIndex += 1
        }
        let slack = 8
        #expect(one >= Self.burstSize)

        let aInside = DispatchSemaphore(value: 0)
        let bAboutToMeasure = DispatchSemaphore(value: 0)
        let a = Worker {
            MallocProbe.measure(slot: slot) {
                // First half of A's work, then wait until B is about to start ITS measurement, then give B time
                // to install (or to block on the lock), then the second half.
                _ = Self.burst(Self.burstSize)
                aInside.signal()
                _ = bAboutToMeasure.wait(timeout: .now() + 5)
                usleep(150_000)
                _ = Self.burst(Self.burstSize)
            }
        }
        let b = Worker {
            _ = aInside.wait(timeout: .now() + 5)
            bAboutToMeasure.signal()
            return MallocProbe.measure(slot: slot) { _ = Self.burst(Self.burstSize) }
        }
        #expect(a.join() && b.join(), "a measurement never finished: the probe deadlocked")
        print("[measured] MallocProbe overlap: one burst = \(one) events; A (2 bursts) = \(a.result.map(String.init) ?? "nil"); "
              + "B (1 burst) = \(b.result.map(String.init) ?? "nil")")
        let aCount = try #require(a.result, "A's hook was taken away")
        let bCount = try #require(b.result, "B's hook was taken away")
        #expect(aCount >= 2 * one - slack, "A lost events to the overlap: \(aCount) < 2 x \(one) - \(slack)")
        #expect(bCount >= one - slack, "B lost events to the overlap: \(bCount) < \(one) - \(slack)")
    }

    @Test("the OLD save-and-restore pattern, as it was written in 17 files, loses counts when two measurements overlap")
    func theLegacyPatternLosesCounts() throws {
        let slot = try #require(MallocProbe.slot(), "malloc_logger is unavailable: FAILURE, not a skip")
        // Two private hooks with two private counters: the shape every file had. Everything below runs inside
        // `exclusively`, so no REAL measurement elsewhere in the process can be hit by this deliberate sabotage.
        // The cells are `static let` heap pointers: a hook runs inside malloc, where a `static var` access (dynamic
        // exclusivity tracking) could itself allocate.
        let counts = LegacyCells.counts
        let watched = LegacyCells.watched
        counts.initialize(repeating: 0, count: 2)
        watched.initialize(repeating: 0, count: 2)
        let hookA: MallocProbe.Hook = { _, _, _, _, _, _ in
            var tid: UInt64 = 0
            pthread_threadid_np(nil, &tid)
            if tid == LegacyCells.watched.pointee { LegacyCells.counts.pointee &+= 1 }
        }
        let hookB: MallocProbe.Hook = { _, _, _, _, _, _ in
            var tid: UInt64 = 0
            pthread_threadid_np(nil, &tid)
            if tid == (LegacyCells.watched + 1).pointee { (LegacyCells.counts + 1).pointee &+= 1 }
        }
        let outcome: (a: Int, b: Int, solo: Int, leaked: Bool) = MallocProbe.exclusively {
            let original = slot.pointee
            defer { slot.pointee = original }
            // Yardstick: one pattern-A measurement alone.
            pthread_threadid_np(nil, &watched.pointee)
            counts.pointee = 0
            let previous = slot.pointee
            slot.pointee = hookA
            _ = Self.burst(Self.burstSize)
            slot.pointee = previous
            let solo = counts.pointee

            // The overlap. Order forced by semaphores: A installs, B installs over it, A works, A restores,
            // B works, B restores.
            let aInstalled = DispatchSemaphore(value: 0)
            let bInstalled = DispatchSemaphore(value: 0)
            let aRestored = DispatchSemaphore(value: 0)
            let a = Worker {
                pthread_threadid_np(nil, &watched.pointee)
                counts.pointee = 0
                let previousA = slot.pointee
                slot.pointee = hookA
                aInstalled.signal()
                _ = bInstalled.wait(timeout: .now() + 5)
                _ = Self.burst(Self.burstSize)       // A's hook has been replaced by B's: lost
                slot.pointee = previousA              // "restore": removes B's hook
                aRestored.signal()
                return counts.pointee
            }
            let b = Worker {
                _ = aInstalled.wait(timeout: .now() + 5)
                pthread_threadid_np(nil, &(watched + 1).pointee)
                (counts + 1).pointee = 0
                let previousB = slot.pointee          // = hookA
                slot.pointee = hookB
                bInstalled.signal()
                _ = aRestored.wait(timeout: .now() + 5)
                _ = Self.burst(Self.burstSize)       // B's hook was removed by A's restore: lost
                slot.pointee = previousB              // puts A's hook back, leaking it
                return (counts + 1).pointee
            }
            let finished = a.join() && b.join()
            let leaked = slot.pointee != nil
            return (a.result ?? -2, b.result ?? -2, finished ? solo : -1, leaked)
        }
        print("[measured] legacy pattern: solo = \(outcome.solo); overlapped A = \(outcome.a), B = \(outcome.b); "
              + "hook left installed afterwards = \(outcome.leaked)")
        #expect(outcome.solo >= Self.burstSize, "control: the legacy hook cannot count even alone (\(outcome.solo))")
        #expect(outcome.a == 0, "A kept \(outcome.a) events although B had replaced its hook")
        #expect(outcome.b == 0, "B kept \(outcome.b) events although A's restore had removed its hook")
        #expect(outcome.leaked, "the legacy pattern was expected to leave a stale hook installed")
    }

    @Test("a hook taken away by foreign code mid-window is reported, never read as a clean count")
    func aForeignSwapIsDetected() throws {
        let slot = try #require(MallocProbe.slot(), "malloc_logger is unavailable: FAILURE, not a skip")
        let swapped = MallocProbe.measure(slot: slot) {
            slot.pointee = nil   // what a stray restore does
        }
        #expect(swapped == nil, "a removed hook produced the count \(swapped.map(String.init) ?? "nil")")
    }

    @Test("no file but the shared probe looks up malloc_logger itself (source read)")
    func onlyTheSharedProbeResolvesTheHook() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        // Built from two halves so this file never matches its own search.
        let needle = "\"malloc" + "_logger\""
        var found: [String] = []
        for dir in ["Tests", "Sources"] {
            let base = root.appendingPathComponent(dir)
            let walker = try #require(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
            for case let url as URL in walker where url.pathExtension == "swift" {
                if try String(contentsOf: url, encoding: .utf8).contains(needle) { found.append(url.path) }
            }
        }
        // Control: the search must reach the helper, or it searched nothing.
        let helper = "Tests/DAWEngineTests/Support/MallocProbe.swift"
        #expect(found.contains { $0.hasSuffix(helper) }, "the search never reached \(helper): \(found)")
        #expect(found.count == 1, "measure through MallocProbe, never a private hook (a second hook loses counts): \(found)")
    }

    private enum LegacyCells {
        nonisolated(unsafe) static let counts = UnsafeMutablePointer<Int>.allocate(capacity: 2)
        nonisolated(unsafe) static let watched = UnsafeMutablePointer<UInt64>.allocate(capacity: 2)
    }
}
