import Darwin
import Foundation
import Testing

/// The ONE malloc probe every allocation gate in this target shares (m39-test-mallocprobe).
///
/// libmalloc's `malloc_logger` is a single PROCESS-WIDE slot. Seventeen test files used to install their own hook
/// into it, each saving the `previous` hook and putting it back when done. Suites run in parallel, so when two
/// measurements overlapped, the first one to finish restored a hook the second no longer owned, and the second LOST
/// counts (MEASURED 2026-10-11: `DrumNoteLayoutRenderTests` F-4 read an idle count of 1,668,971 against an expected
/// 3,481,600 inside a 2,306-test run). The dangerous half: a gate that asserts ZERO allocations passes falsely when
/// its hook has been taken away.
///
/// The fix is one lock held for the WHOLE install -> measure -> restore window, plus one pair of counter cells, so
/// two measurements can never overlap anywhere in the process. Windows are synchronous (no suspension point), so
/// holding a plain lock cannot deadlock the cooperative pool.
///
/// Rules for a body:
/// - It must not call `MallocProbe` again (the lock is not recursive: a nested call would hang, loudly).
/// - Allocate everything the measurement needs BEFORE the window; the hook counts every malloc/free on the calling thread.
/// - Use `while`, never `for ... in 0..<n`, inside a zero-allocation body (the -Onone Range-iteration malloc law).
enum MallocProbe {
    typealias Hook = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
    typealias Slot = UnsafeMutablePointer<Hook?>

    /// Heap cells, NOT stored properties read lazily inside the hook: the hook runs INSIDE malloc with its locks
    /// held, so it must never allocate nor trip a lazy global initialiser. `events(...)` touches both before the
    /// hook is installed.
    private nonisolated(unsafe) static let eventCount = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private nonisolated(unsafe) static let watchedThread = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    private static let windowLock = NSLock()

    private static let eventHook: Hook = { _, _, _, _, _, _ in
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)  // no allocation, safe under malloc
        if tid == MallocProbe.watchedThread.pointee {
            MallocProbe.eventCount.pointee &+= 1
        }
    }

    /// libmalloc's `malloc_logger` global, or nil when the symbol is missing. Nil is a FAILURE for the caller,
    /// never a skip: a silently absent probe is vacuity, not a pass.
    static func slot() -> Slot? {
        guard let raw = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        return raw.assumingMemoryBound(to: Hook?.self)
    }

    /// `slot() != nil`, for gates that only need to know whether the probe can run.
    static var isAvailable: Bool { slot() != nil }

    /// Malloc/free events raised on THIS thread while `body` runs, or nil when something outside this type took
    /// the hook away mid-window (which would otherwise read as a false zero). `warmup` runs with the hook live and
    /// the counter is zeroed after it, because Swift's lazy globals allocate on first touch anywhere in the process.
    /// Holds the process-wide lock for the whole window.
    static func measure(slot: Slot, warmup: () -> Void = {}, _ body: () -> Void) -> Int? {
        windowLock.lock()
        defer { windowLock.unlock() }
        pthread_threadid_np(nil, &watchedThread.pointee)
        eventCount.pointee = 0
        let previous = slot.pointee  // restore, don't assume it was nil
        slot.pointee = eventHook
        warmup()
        eventCount.pointee = 0  // one-time lazy-global costs are not the measurement
        body()
        // A plain load while the hook is still installed; the comparison runs AFTER the restore, because at
        // `-Onone` its `Optional.map` + generic `==` instantiate metadata on first use (measured as 6 events
        // inside the window when this compare sat before the restore).
        let current = slot.pointee
        slot.pointee = previous
        let events = eventCount.pointee
        let intact = current.map { unsafeBitCast($0, to: UnsafeRawPointer.self) }
            == unsafeBitCast(eventHook, to: UnsafeRawPointer.self)
        return intact ? events : nil
    }

    /// `measure`, failing closed: a hook taken away mid-window records an issue and returns -1, so a
    /// "== 0" gate and a "> 0" control both fail instead of passing on a probe that stopped listening.
    static func events(slot: Slot, warmup: () -> Void = {}, _ body: () -> Void) -> Int {
        if let events = measure(slot: slot, warmup: warmup, body) { return events }
        Issue.record("the malloc_logger hook was replaced by code outside MallocProbe mid-measurement; the count is void")
        return -1
    }

    /// Runs `body` holding the same lock a measurement holds, for the one test that must pull the process-wide
    /// slot out from under its own hooks on purpose (the legacy-pattern demonstration). `body` must not call
    /// `measure` or `events`.
    static func exclusively<T>(_ body: () -> T) -> T {
        windowLock.lock()
        defer { windowLock.unlock() }
        return body()
    }
}
