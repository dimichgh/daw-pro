import Foundation
import Testing

@testable import AIServices

/// Pure derivation tests for `ModelMemory.Snapshot` — m23-dl §7.1.
///
/// Every snapshot here is hand-built, so nothing in this suite reads the host
/// and nothing depends on how much Chrome the developer has open. That is the
/// whole point of splitting the derivation out of `sample()`: the thresholds
/// admission turns on become deterministic.
@Suite("ModelMemory — pure derivations (m23-dl)")
struct ModelMemoryTests {

    /// 16 KB, the measured `vm_kernel_page_size` on Apple silicon. Not 4096 —
    /// a test written against the Intel page size would produce byte figures
    /// four times too small and still "pass" its own arithmetic.
    private static let pageSize: UInt64 = 16384
    private static let gib: UInt64 = 1 << 30

    private static func pages(_ gigabytes: UInt64) -> UInt64 {
        gigabytes * gib / pageSize
    }

    /// The idle-machine sample recorded in the design (§0.2), reproduced
    /// exactly, so the numbers below can be checked against a `vm_stat` a human
    /// can run.
    private static func measuredIdleSnapshot() -> ModelMemory.Snapshot {
        ModelMemory.snapshot(
            pageSize: pageSize,
            physical: 137_438_953_472,      // 128 GiB, `hw.memsize`
            internalPages: 4_214_718,
            purgeablePages: 126_944,
            wirePages: 425_949,
            compressorPages: 0,
            freePages: 2_205_114,
            speculativePages: 219_986,
            externalPages: 1_676_108,
            at: Date(timeIntervalSince1970: 0))
    }

    // MARK: - The three derived figures

    // ⚠️ UNITS. The design's §0.2 derived figures — "68.87 GB" used, "59.13 GB"
    // available — are **GiB**, not GB, as the arithmetic below demonstrates.
    // Its §16.1 figures ("80 GB (≈ 74.5 GiB)") are genuinely base-10 GB. Mixing
    // the two silently is how a refusal message ends up quoting a requirement in
    // GiB and an availability in GB, and reporting a shortfall that is off by
    // 7%. Everything in this module stores BYTES and every user-facing figure
    // goes through `ModelMemory.formatGB` (base-10, Activity Monitor's unit).
    @Test("usedBytes is Activity Monitor's Memory Used: internal − purgeable + wired + compressor")
    func usedBytesMatchesActivityMonitorFormula() {
        let snapshot = Self.measuredIdleSnapshot()
        let expected = (4_214_718 - 126_944 + 425_949 + 0) * Self.pageSize
        #expect(snapshot.usedBytes == expected)
        #expect(snapshot.usedBytes == 73_952_837_632)
        // The design's "68.87 GB" — which is 68.87 GiB, i.e. 73.95 base-10 GB.
        #expect(abs(Double(snapshot.usedBytes) / Double(Self.gib) - 68.87) < 0.01)
        #expect(ModelMemory.formatGB(snapshot.usedBytes) == "74.0 GB")
    }

    @Test("availableBytes is physical − used, and it is what admission spends")
    func availableBytesIsPhysicalMinusUsed() {
        let snapshot = Self.measuredIdleSnapshot()
        #expect(snapshot.availableBytes == snapshot.physicalBytes - snapshot.usedBytes)
        #expect(snapshot.availableBytes == 63_486_115_840)
        // The design's "59.13 GB", again GiB.
        #expect(abs(Double(snapshot.availableBytes) / Double(Self.gib) - 59.13) < 0.01)
    }

    @Test("vmStatFreeBytes is free MINUS speculative — the number `vm_stat` prints")
    func vmStatFreeSubtractsSpeculative() {
        let snapshot = Self.measuredIdleSnapshot()
        #expect(snapshot.vmStatFreeBytes == (2_205_114 - 219_986) * Self.pageSize)
        // And it is NOT freeBytes: a human comparing the two would otherwise
        // read a ~3.4 GB phantom bug.
        #expect(snapshot.vmStatFreeBytes < snapshot.freeBytes)
        #expect(snapshot.freeBytes - snapshot.vmStatFreeBytes == 219_986 * Self.pageSize)
    }

    // MARK: - The file-backed shape (the reason this metric was chosen)

    @Test("A large file-backed mapping moves externalBytes and leaves usedBytes alone")
    func fileBackedPagesAreNotAHold() {
        let baseline = ModelMemory.snapshot(
            pageSize: Self.pageSize, physical: 128 * Self.gib,
            internalPages: Self.pages(40), purgeablePages: 0, wirePages: Self.pages(6),
            compressorPages: 0, freePages: Self.pages(30), speculativePages: Self.pages(3),
            externalPages: Self.pages(25), at: Date(timeIntervalSince1970: 0))
        // The measured file-backed shape: +4 GiB of page cache, no change to
        // anonymous or wired pages.
        let withCache = ModelMemory.snapshot(
            pageSize: Self.pageSize, physical: 128 * Self.gib,
            internalPages: Self.pages(40), purgeablePages: 0, wirePages: Self.pages(6),
            compressorPages: 0, freePages: Self.pages(26), speculativePages: Self.pages(3),
            externalPages: Self.pages(29), at: Date(timeIntervalSince1970: 1))

        #expect(withCache.externalBytes > baseline.externalBytes)
        #expect(withCache.freeBytes < baseline.freeBytes)
        // THE POINT: admission's number does not move for reclaimable cache.
        #expect(withCache.usedBytes == baseline.usedBytes)
        #expect(withCache.availableBytes == baseline.availableBytes)
    }

    @Test("An anonymous hold DOES move usedBytes — the anti-vacuity twin")
    func anonymousPagesAreAHold() {
        let baseline = ModelMemory.snapshot(
            pageSize: Self.pageSize, physical: 128 * Self.gib,
            internalPages: Self.pages(40), purgeablePages: 0, wirePages: Self.pages(6),
            compressorPages: 0, freePages: Self.pages(30), speculativePages: Self.pages(3),
            externalPages: Self.pages(25), at: Date(timeIntervalSince1970: 0))
        let withHold = ModelMemory.snapshot(
            pageSize: Self.pageSize, physical: 128 * Self.gib,
            internalPages: Self.pages(48), purgeablePages: 0, wirePages: Self.pages(6),
            compressorPages: 0, freePages: Self.pages(22), speculativePages: Self.pages(3),
            externalPages: Self.pages(25), at: Date(timeIntervalSince1970: 1))

        #expect(withHold.usedBytes == baseline.usedBytes + 8 * Self.gib)
        #expect(withHold.availableBytes == baseline.availableBytes - 8 * Self.gib)
    }

    @Test("Compressed pages count as a hold")
    func compressorPagesAreAHold() {
        let uncompressed = ModelMemory.snapshot(
            pageSize: Self.pageSize, physical: 128 * Self.gib,
            internalPages: Self.pages(40), purgeablePages: 0, wirePages: Self.pages(6),
            compressorPages: 0, freePages: Self.pages(30), speculativePages: 0,
            externalPages: Self.pages(25), at: Date(timeIntervalSince1970: 0))
        let compressed = ModelMemory.snapshot(
            pageSize: Self.pageSize, physical: 128 * Self.gib,
            internalPages: Self.pages(40), purgeablePages: 0, wirePages: Self.pages(6),
            compressorPages: Self.pages(5), freePages: Self.pages(30), speculativePages: 0,
            externalPages: Self.pages(25), at: Date(timeIntervalSince1970: 1))
        #expect(compressed.usedBytes == uncompressed.usedBytes + 5 * Self.gib)
    }

    // MARK: - Saturation: these are UInt64, and wrapping refuses everything

    @Test("purgeable > internal saturates instead of wrapping to 18 exabytes")
    func purgeableLargerThanInternalDoesNotUnderflow() {
        let snapshot = ModelMemory.snapshot(
            pageSize: Self.pageSize, physical: 128 * Self.gib,
            internalPages: Self.pages(2), purgeablePages: Self.pages(9),
            wirePages: Self.pages(6), compressorPages: 0, freePages: Self.pages(100),
            speculativePages: 0, externalPages: 0, at: Date(timeIntervalSince1970: 0))
        // internal − purgeable saturates at 0, so used == wired.
        #expect(snapshot.usedBytes == 6 * Self.gib)
        #expect(snapshot.availableBytes == 122 * Self.gib)
        // The failure this guards: an unsaturated subtraction wraps, used
        // becomes astronomically large, available becomes 0, and admission
        // silently refuses every model on every machine.
        #expect(snapshot.usedBytes < snapshot.physicalBytes)
    }

    @Test("used > physical saturates availableBytes to zero, never wraps")
    func usedLargerThanPhysicalDoesNotUnderflow() {
        let snapshot = ModelMemory.snapshot(
            pageSize: Self.pageSize, physical: 8 * Self.gib,
            internalPages: Self.pages(60), purgeablePages: 0, wirePages: Self.pages(4),
            compressorPages: 0, freePages: 0, speculativePages: 0, externalPages: 0,
            at: Date(timeIntervalSince1970: 0))
        #expect(snapshot.usedBytes > snapshot.physicalBytes)
        #expect(snapshot.availableBytes == 0)
    }

    @Test("speculative > free saturates vmStatFreeBytes to zero")
    func speculativeLargerThanFreeDoesNotUnderflow() {
        let snapshot = ModelMemory.snapshot(
            pageSize: Self.pageSize, physical: 128 * Self.gib,
            internalPages: Self.pages(40), purgeablePages: 0, wirePages: Self.pages(6),
            compressorPages: 0, freePages: Self.pages(1), speculativePages: Self.pages(3),
            externalPages: 0, at: Date(timeIntervalSince1970: 0))
        #expect(snapshot.vmStatFreeBytes == 0)
    }

    // MARK: - Codable (the wire never drifts)

    @Test("A snapshot round-trips through JSON with every counter intact")
    func snapshotRoundTrips() throws {
        let original = Self.measuredIdleSnapshot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            ModelMemory.Snapshot.self, from: try encoder.encode(original))
        #expect(decoded == original)
        #expect(decoded.availableBytes == original.availableBytes)
    }

    // MARK: - Tree attribution: "could not ask" is not "found nothing"

    @Test("treeUsage sums readable pids and lists unreadable ones separately")
    func treeUsageSumsAndReportsUnreadable() {
        let usage = ModelMemory.treeUsage(pids: [100, 101, 102]) { pid in
            switch pid {
            case 100: return (footprint: 1_000, resident: 5_000)
            case 101: return nil                       // root-owned: rusage fails
            case 102: return (footprint: 2_000, resident: 7_000)
            default: return nil
            }
        }
        #expect(usage.pids == [100, 102])
        #expect(usage.footprintBytes == 3_000)
        #expect(usage.residentBytes == 12_000)
        // NOT silently counted as zero — the whole m23-az-1 lesson.
        #expect(usage.unreadablePids == [101])
    }

    @Test("A tree where nothing is readable reports zero totals AND names every pid")
    func treeUsageWithNothingReadableIsHonest() {
        let usage = ModelMemory.treeUsage(pids: [1, 2]) { _ in nil }
        #expect(usage.pids.isEmpty)
        #expect(usage.footprintBytes == 0)
        #expect(usage.unreadablePids == [1, 2])
        // The anti-vacuity point: a caller can distinguish this from a tree
        // that was fully read and genuinely holds nothing.
        let readEmpty = ModelMemory.treeUsage(pids: [1, 2]) { _ in (footprint: 0, resident: 0) }
        #expect(readEmpty.unreadablePids.isEmpty)
        #expect(readEmpty.footprintBytes == 0)
        #expect(usage != readEmpty)
    }

    @Test("treeUsage walks the whole tree, not just the root pid")
    func treeUsageCoversDescendants() {
        // The measured ACE topology: run.sh (99) → uv (100) → python (101),
        // and the CHILD is what holds the memory. A sum over the root alone
        // is the "~1 GB for a ~75 GB hold" reading.
        let snapshot = SidecarProcessDiscovery.Snapshot(entries: [
            .init(pid: 99, ppid: 1, args: "/bin/bash /repo/scripts/ace-step/run.sh"),
            .init(pid: 100, ppid: 99, args: "uv run --no-sync acestep-api"),
            .init(pid: 101, ppid: 100, args: "/venv/bin/python3 /venv/bin/acestep-api"),
        ])
        let pids = [99] + snapshot.descendants(of: 99).map(\.pid)
        #expect(pids == [99, 100, 101])

        let usage = ModelMemory.treeUsage(pids: pids) { pid in
            pid == 101 ? (footprint: 75_000_000_000, resident: 80_000_000_000)
                       : (footprint: 1_000_000_000, resident: 1_000_000_000)
        }
        #expect(usage.footprintBytes == 77_000_000_000)
        // Root-only would have reported 1 GB. That is the trap this exists for.
        let rootOnly = ModelMemory.treeUsage(pids: [99]) { _ in
            (footprint: 1_000_000_000, resident: 1_000_000_000)
        }
        #expect(rootOnly.footprintBytes == 1_000_000_000)
    }

    // MARK: - Formatting

    @Test("GB formatting is base-10, matching Activity Monitor")
    func formatsInBaseTenGigabytes() {
        #expect(ModelMemory.formatGB(UInt64(75_010_277_376)) == "75.0 GB")
        #expect(ModelMemory.formatGB(Int64(-2_100_000_000)) == "-2.1 GB")
    }
}
