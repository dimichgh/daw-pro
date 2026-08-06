import Darwin
import Foundation
import Testing

@testable import AIServices

/// THE POSITIVE CONTROL FOR THE METRIC ITSELF — m23-dl §7.2.
///
/// Without this, a `ModelMemory.sample()` that returned all zeros would pass
/// every pure test in `ModelMemoryTests`: they only check derivations, and
/// zeros derive perfectly. This suite is the only thing in the item that proves
/// the mach trap reports a real machine.
///
/// It is also the gate on the whole feature (§10 step 1): *"if `availableBytes`
/// does not move by ≥ 1 GiB under a touched 2 GiB allocation, stop; nothing
/// downstream is worth building."*
///
/// **`.serialized`** because two 2 GiB allocations overlapping under Swift
/// Testing's default parallelism would double the footprint and could make the
/// recovery assertion read another test's release as its own.
///
/// ⚠️ **The skip guard is on AVAILABLE memory, never on `physicalMemory`.** A
/// total-RAM guard is the wrong check and it is the one that looks right: this
/// very 128 GB machine sits at ~57-61 GB available and drops far lower under a
/// real workload, so `physicalMemory >= 16 GiB` would happily allocate 2 GiB
/// into a machine that is already compressing — a test that degrades the thing
/// it is measuring.
@Suite("ModelMemory — live sample, positive control (m23-dl §7.2)", .serialized)
struct ModelMemoryLiveTests {

    private static let gib = 1 << 30
    /// Enough headroom that a 2 GiB hold cannot itself push the machine into
    /// compression. Skip below this rather than measure a degraded machine.
    private static let minimumAvailableBytes = UInt64(8 * gib)

    static var hasHeadroom: Bool {
        ModelMemory.sample().availableBytes >= minimumAvailableBytes
    }

    @Test(
        "A touched 2 GiB anonymous allocation moves availableBytes, and releasing it moves it back",
        .enabled(if: ModelMemoryLiveTests.hasHeadroom))
    func availableBytesTracksARealHold() throws {
        let holdBytes = 2 * Self.gib
        let pageSize = Int(ModelMemory.systemPageSize())

        #expect(pageSize == 16384 || pageSize == 4096, "unexpected kernel page size \(pageSize)")

        // ⚠️⚠️ **RETRIED, AND THE RETRY IS A CONTENTION GUARD — NOT A RELAXED
        // THRESHOLD.** Every attempt asserts the SAME full-strength ≥ 1 GiB
        // claim; the loop only says "another suite's churn swamped that
        // sample, take another one". `host_statistics64` reports the whole
        // MACHINE, and this suite runs in parallel with ~500 other tests that
        // allocate and free continuously — MEASURED: this test passes alone in
        // 0.52 s and has recorded a delta of exactly 0 GB inside a full run.
        // A broken metric still fails every attempt, so the positive control is
        // intact: what the retry removes is a verdict that depends on what the
        // scheduler was doing, which is the "fails for unrelated reasons" class
        // this codebase keeps paying for.
        let attempts = 4
        var lastHeld: Int64 = 0
        var lastAvailableDrop: Int64 = 0
        var lastResidual: Int64 = 0
        var succeeded = false

        for attempt in 1...attempts {
            let before = ModelMemory.sample()
            // Sanity: the trap actually reported a machine, not the all-zero
            // fallback. Without this the deltas below could both be zero-vs-zero.
            #expect(before.physicalBytes > UInt64(4 * Self.gib))
            #expect(before.usedBytes > 0)
            #expect(before.pageSizeBytes == UInt64(pageSize))

            let region = mmap(
                nil, holdBytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
            try #require(region != MAP_FAILED, "could not mmap 2 GiB")
            let base = try #require(region).assumingMemoryBound(to: UInt8.self)

            var released = false
            defer { if !released { munmap(region, holdBytes) } }

            // ⚠️ TOUCH EVERY PAGE. An untouched anonymous mapping is a promise,
            // not a hold: no physical page is committed until it is written, so
            // a test that skips this measures nothing and passes vacuously.
            //
            // ⚠️⚠️ AND THE FILL MUST BE INCOMPRESSIBLE. This loop used to write
            // one constant byte per page, which leaves the remaining ~16 KB of
            // each page zero-filled — and macOS's compressor squashes a page
            // like that to almost nothing. The pages then move OUT of
            // `internal_page_count` and into `compressor_page_count` at a
            // fraction of the size, so `usedBytes` barely moves and the "2 GiB
            // hold" is not a hold at all. MEASURED: this test recorded a delta
            // of EXACTLY 0 GB on a loaded machine while passing on an idle one.
            // `arc4random_buf` fills every byte with incompressible noise, which
            // is also the honest analogue: a model's weights do not compress
            // either.
            arc4random_buf(region, holdBytes)

            // Read back so the fill cannot be optimised away, and so a mapping
            // that silently failed to commit shows up as an all-zero region.
            var checksum: UInt64 = 0
            for offset in stride(from: 0, to: holdBytes, by: pageSize) {
                checksum &+= UInt64(base[offset])
            }
            #expect(checksum > 0, "the 2 GiB mapping read back as all zeros — nothing was committed")

            let during = ModelMemory.sample()
            lastHeld = Int64(during.usedBytes) - Int64(before.usedBytes)
            lastAvailableDrop = Int64(before.availableBytes) - Int64(during.availableBytes)

            munmap(region, holdBytes)
            released = true

            let after = ModelMemory.sample()
            lastResidual = Int64(after.usedBytes) - Int64(before.usedBytes)

            // Grounded in measurement: an 8 GiB hold moved `available` by
            // 8.19 GB and idle drift between adjacent samples is ±0.3 GB, so a
            // 2 GiB hold asserted at ≥ 1 GiB is comfortably outside noise in
            // both directions.
            if lastHeld >= Int64(1 * Self.gib),
               lastAvailableDrop >= Int64(1 * Self.gib),
               lastResidual < Int64(1 * Self.gib) {
                succeeded = true
                break
            }
            if attempt < attempts {
                // Let whatever else is running settle before re-measuring.
                Thread.sleep(forTimeInterval: 0.25)
            }
        }

        #expect(
            succeeded,
            """
            after \(attempts) attempts the metric never tracked a touched 2 GiB anonymous hold. \
            Last attempt: usedBytes rose \(ModelMemory.formatGB(lastHeld)), availableBytes fell \
            \(ModelMemory.formatGB(lastAvailableDrop)), residual after munmap \
            \(ModelMemory.formatGB(lastResidual)).
            """)
    }

    @Test("sample() reports a coherent machine, not the all-zero trap fallback")
    func sampleReportsACoherentMachine() {
        let snapshot = ModelMemory.sample()
        #expect(snapshot.physicalBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(snapshot.pageSizeBytes == 16384 || snapshot.pageSizeBytes == 4096)
        // Every one of these is zero in the fallback branch, so together they
        // prove `host_statistics64` succeeded.
        #expect(snapshot.internalBytes > 0)
        #expect(snapshot.wiredBytes > 0)
        #expect(snapshot.usedBytes > 0)
        #expect(snapshot.usedBytes < snapshot.physicalBytes)
        #expect(snapshot.availableBytes > 0)
        #expect(snapshot.availableBytes + snapshot.usedBytes == snapshot.physicalBytes)
    }

    @Test("proc_pid_rusage reads this process, and reports pid 1 as unreadable rather than zero")
    func treeUsageIsHonestAboutWhatItCannotRead() {
        let mine = ModelMemory.processUsage(of: getpid())
        #expect(mine != nil, "proc_pid_rusage must succeed for our own pid")
        #expect((mine?.resident ?? 0) > 0)

        // Measured: root-owned pids fail. The check must say so, not report 0.
        let usage = ModelMemory.treeUsage(pids: [getpid(), 1], usage: ModelMemory.processUsage(of:))
        #expect(usage.pids == [getpid()])
        #expect(usage.unreadablePids == [1])
        #expect(usage.residentBytes > 0)
    }
}
