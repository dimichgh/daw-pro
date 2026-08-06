import Darwin
import Foundation

/// One home (house "ONE home" rule) for *"how much memory does this machine
/// actually have left, and what is this process tree holding?"* — m23-dl.
///
/// ## Why this metric and not one of the five obvious ones
///
/// Measured on the user's M5 Max / 128 GB machine 2026-08-05 with three
/// allocation shapes (8 GiB anonymous `mmap`, 8 GiB Metal `.storageModeShared`,
/// 4 GiB file-backed `mmap`), each touched page-by-page, held, then `SIGKILL`ed:
///
/// | shape | `ps` RSS | `ri_phys_footprint` | Δ `free` | Δ Activity-Monitor used |
/// |---|---|---|---|---|
/// | anonymous 8 GiB | 8.01 GB | 8.01 GB | −8.02 | **+8.19** |
/// | Metal shared 8 GiB | 8.01 GB | 8.01 GB | −7.86 | **+7.69** |
/// | file-backed 4 GiB | 4.01 GB | **0.00 GB** | −2.10 | **−0.52** |
///
/// Only the last column is correct for all three: it counts the two shapes that
/// are a genuine hold and correctly ignores reclaimable file cache. So:
///
/// * **`phys_footprint` is the metric that lies, not RSS.** A 4 GiB file-backed
///   mapping is charged **0.00 GB** of footprint. `safetensors` mmaps
///   checkpoints by default and ACE-Step's checkpoint tree is 56 GB, so a
///   footprint-based residency check would report a mmap-loaded model as holding
///   nothing. It is reported here for attribution and **decides nothing**.
/// * **`free_count` is also wrong.** It fell 2.10 GB for the file case where
///   nothing was really held, it drifts ±0.3 GB between adjacent idle samples,
///   and it does **not** come back on process exit for file-backed pages — so an
///   "unloaded" assertion built on it FAILS for a correctly-unloaded model.
/// * **Metal/MPS unified memory needs no special accounting** — an 8 GiB
///   `.storageModeShared` buffer landed in RSS, footprint and
///   `internal_page_count` exactly like malloc'd memory. Measured, not assumed.
///
/// ## What is deliberately NOT here
///
/// `task_for_pid` / `task_info(TASK_VM_INFO)` on a foreign pid: measured
/// `KERN_FAILURE (5)` against both a same-uid pid and pid 1. It needs the
/// `com.apple.security.cs.debugger` entitlement plus a signed hardened-runtime
/// binary, which collides with the standing decision that DAW Pro ships ad-hoc
/// signed for local use. **Do not add it** — at runtime it fails in a way that
/// reads as "the check silently returned nil".
///
/// `kern.memorystatus_level` (measured `94`): undocumented, and the published
/// counters do not reproduce it (best reconstruction gave 96.5). Fine as a
/// corroborating signal, never the number a decision turns on.
///
/// ## Real-time safety
///
/// Nothing here is reachable from the render thread. `sample()` is one mach trap
/// and no allocation beyond the returned struct — cheap enough for a 1 Hz UI
/// poll off the main actor. `treeUsage(rootPid:snapshot:)` is also allocation-
/// light, but the `SidecarProcessDiscovery.Snapshot` it consumes costs a `/bin/ps`
/// fork, so **that** must never be taken from a `@MainActor` view body or a
/// main-actor polling timer.
public enum ModelMemory {

    // MARK: - The snapshot

    /// A single `host_statistics64(HOST_VM_INFO64)` sample, in bytes.
    ///
    /// `Codable` so it can go on the wire verbatim (house "the wire never
    /// drifts" rule) and so a support bundle can carry the exact counters a
    /// decision was made from.
    ///
    /// Every derived figure below is a computed property, which is what makes
    /// every threshold in `ModelAdmission` testable by hand-building a snapshot
    /// instead of reading the host.
    public struct Snapshot: Codable, Sendable, Equatable {
        public var pageSizeBytes: UInt64
        public var physicalBytes: UInt64
        /// Anonymous (malloc'd, Metal-shared, stack) pages — a genuine hold.
        public var internalBytes: UInt64
        public var purgeableBytes: UInt64
        public var wiredBytes: UInt64
        public var compressorBytes: UInt64
        public var freeBytes: UInt64
        public var speculativeBytes: UInt64
        /// File-backed / page cache. Reclaimable, so it is NOT a hold — and it
        /// does not return to `free` when the mapping process dies (measured).
        public var externalBytes: UInt64
        public var sampledAt: Date

        public init(
            pageSizeBytes: UInt64, physicalBytes: UInt64, internalBytes: UInt64,
            purgeableBytes: UInt64, wiredBytes: UInt64, compressorBytes: UInt64,
            freeBytes: UInt64, speculativeBytes: UInt64, externalBytes: UInt64,
            sampledAt: Date
        ) {
            self.pageSizeBytes = pageSizeBytes
            self.physicalBytes = physicalBytes
            self.internalBytes = internalBytes
            self.purgeableBytes = purgeableBytes
            self.wiredBytes = wiredBytes
            self.compressorBytes = compressorBytes
            self.freeBytes = freeBytes
            self.speculativeBytes = speculativeBytes
            self.externalBytes = externalBytes
            self.sampledAt = sampledAt
        }

        /// Activity Monitor's "Memory Used". **THE** metric — the only one of six
        /// that tracked all three measured allocation shapes correctly.
        ///
        /// The `min` is not defensive noise: these are `UInt64`, and a sample
        /// where `purgeable > internal` (legal — they are independently
        /// maintained counters) would otherwise wrap to ~18 exabytes and make
        /// `availableBytes` zero, i.e. refuse everything, silently.
        public var usedBytes: UInt64 {
            internalBytes - min(internalBytes, purgeableBytes) + wiredBytes + compressorBytes
        }

        /// What admission spends. Deliberately **not** `freeBytes`.
        public var availableBytes: UInt64 {
            physicalBytes - min(physicalBytes, usedBytes)
        }

        /// `vm_stat`'s printed *"Pages free"*, which is `free_count` **minus**
        /// `speculative_count` — not `free_count`. Exposed only so a human
        /// reconciling our numbers against `vm_stat` does not read a ~3.4 GB
        /// phantom bug. Verified: `free 2205114 − speculative 219986 = 1985128`
        /// against a `vm_stat` sample of `1967839` seconds later.
        public var vmStatFreeBytes: UInt64 {
            freeBytes - min(freeBytes, speculativeBytes)
        }

        // MARK: Codable
        //
        // ⚠️ **The three DERIVED figures are ENCODED, and that is not redundancy.**
        // `usedBytes`, `availableBytes` and `vmStatFreeBytes` are computed
        // properties, so synthesised `Codable` would leave them off the wire
        // entirely — and they are the only three a human or an agent actually
        // reads. `ai.modelResidency`'s whole contract is that `usedBytes` equals
        // Activity Monitor's "Memory Used" and that `vmStatFreeBytes` is the
        // number `vm_stat` prints; a reader who had to re-derive them from six
        // raw counters would get the `min()` saturation wrong (which is exactly
        // how a sample with `purgeable > internal` reads as ~18 exabytes).
        //
        // Decoding ignores them and recomputes: the STORED counters remain the
        // single source of truth, so a hand-edited derived value on the way in
        // cannot make a snapshot self-inconsistent.

        enum CodingKeys: String, CodingKey {
            case pageSizeBytes, physicalBytes, internalBytes, purgeableBytes, wiredBytes
            case compressorBytes, freeBytes, speculativeBytes, externalBytes, sampledAt
            case usedBytes, availableBytes, vmStatFreeBytes
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pageSizeBytes, forKey: .pageSizeBytes)
            try container.encode(physicalBytes, forKey: .physicalBytes)
            try container.encode(internalBytes, forKey: .internalBytes)
            try container.encode(purgeableBytes, forKey: .purgeableBytes)
            try container.encode(wiredBytes, forKey: .wiredBytes)
            try container.encode(compressorBytes, forKey: .compressorBytes)
            try container.encode(freeBytes, forKey: .freeBytes)
            try container.encode(speculativeBytes, forKey: .speculativeBytes)
            try container.encode(externalBytes, forKey: .externalBytes)
            try container.encode(sampledAt, forKey: .sampledAt)
            try container.encode(usedBytes, forKey: .usedBytes)
            try container.encode(availableBytes, forKey: .availableBytes)
            try container.encode(vmStatFreeBytes, forKey: .vmStatFreeBytes)
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pageSizeBytes = try container.decode(UInt64.self, forKey: .pageSizeBytes)
            physicalBytes = try container.decode(UInt64.self, forKey: .physicalBytes)
            internalBytes = try container.decode(UInt64.self, forKey: .internalBytes)
            purgeableBytes = try container.decode(UInt64.self, forKey: .purgeableBytes)
            wiredBytes = try container.decode(UInt64.self, forKey: .wiredBytes)
            compressorBytes = try container.decode(UInt64.self, forKey: .compressorBytes)
            freeBytes = try container.decode(UInt64.self, forKey: .freeBytes)
            speculativeBytes = try container.decode(UInt64.self, forKey: .speculativeBytes)
            externalBytes = try container.decode(UInt64.self, forKey: .externalBytes)
            sampledAt = try container.decode(Date.self, forKey: .sampledAt)
        }
    }

    // MARK: - Pure construction (page counts → bytes)

    /// PURE. Builds a snapshot from raw page counts, exactly as `sample()` does,
    /// so a test can reproduce any machine state — including ones this machine
    /// cannot be put into — without reading the host.
    public static func snapshot(
        pageSize: UInt64, physical: UInt64, internalPages: UInt64, purgeablePages: UInt64,
        wirePages: UInt64, compressorPages: UInt64, freePages: UInt64,
        speculativePages: UInt64, externalPages: UInt64, at sampledAt: Date
    ) -> Snapshot {
        Snapshot(
            pageSizeBytes: pageSize,
            physicalBytes: physical,
            internalBytes: internalPages * pageSize,
            purgeableBytes: purgeablePages * pageSize,
            wiredBytes: wirePages * pageSize,
            compressorBytes: compressorPages * pageSize,
            freeBytes: freePages * pageSize,
            speculativeBytes: speculativePages * pageSize,
            externalBytes: externalPages * pageSize,
            sampledAt: sampledAt)
    }

    // MARK: - Impure: the one mach trap

    /// IMPURE, but tiny: one `host_statistics64` trap, microseconds, no
    /// allocation beyond the returned struct and no fork.
    ///
    /// Falls back to a snapshot whose counters are all zero **except**
    /// `physicalBytes` when the trap fails, which makes `availableBytes` equal
    /// the whole machine. That is deliberate: the trap has never been observed
    /// to fail (no entitlement, no privilege), and if it ever does, a lifecycle
    /// manager that refuses every boot because it could not measure is worse
    /// than one that admits and lets the OS arbitrate. The zero counters are
    /// visible in the snapshot, so the condition is diagnosable rather than
    /// disguised.
    /// The kernel page size every `vm_statistics64` counter is denominated in
    /// — 16384 on Apple silicon, 4096 on Intel.
    ///
    /// ⚠️ **Not `vm_kernel_page_size`/`vm_page_size`.** Those are mutable
    /// globals in `Darwin`, so under Swift 6 strict concurrency reading either
    /// is a hard error ("reference to var … is not concurrency-safe"). The trap
    /// is the same number without the global.
    public static func systemPageSize() -> UInt64 {
        var pageSize: vm_size_t = 0
        if host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 {
            return UInt64(pageSize)
        }
        let fallback = sysconf(_SC_PAGESIZE)
        return fallback > 0 ? UInt64(fallback) : 4096
    }

    public static func sample(at sampledAt: Date = Date()) -> Snapshot {
        let physical = ProcessInfo.processInfo.physicalMemory
        let pageSize = systemPageSize()

        var stats = vm_statistics64_data_t()
        // Exactly `HOST_VM_INFO64_COUNT`: sizeof(struct)/sizeof(integer_t).
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return Snapshot(
                pageSizeBytes: pageSize, physicalBytes: physical, internalBytes: 0,
                purgeableBytes: 0, wiredBytes: 0, compressorBytes: 0, freeBytes: 0,
                speculativeBytes: 0, externalBytes: 0, sampledAt: sampledAt)
        }
        return snapshot(
            pageSize: pageSize,
            physical: physical,
            internalPages: UInt64(stats.internal_page_count),
            purgeablePages: UInt64(stats.purgeable_count),
            wirePages: UInt64(stats.wire_count),
            compressorPages: UInt64(stats.compressor_page_count),
            freePages: UInt64(stats.free_count),
            speculativePages: UInt64(stats.speculative_count),
            externalPages: UInt64(stats.external_page_count),
            at: sampledAt)
    }

    // MARK: - Attribution (never a verdict)

    /// Per-process-tree `proc_pid_rusage` totals.
    ///
    /// ⚠️ **This never decides anything.** `ri_phys_footprint` reports
    /// **0.00 GB** for a 4 GiB file-backed mapping (measured), so a model whose
    /// weights are mmap'd looks free. Both fields are reported because a
    /// footprint far below resident is the *fingerprint* of an mmap'd model,
    /// which is diagnostic gold — but the verdict belongs to `Snapshot`.
    public struct TreeUsage: Codable, Sendable, Equatable {
        /// The pids that were readable, root first.
        public var pids: [Int32]
        public var footprintBytes: UInt64
        public var residentBytes: UInt64
        /// Pids whose `proc_pid_rusage` failed. Reported honestly rather than
        /// counted as zero: "could not ask" is not "found nothing" (m23-az-1).
        /// Measured to be non-empty for root-owned pids — `proc_pid_rusage(1)`
        /// returns −1.
        public var unreadablePids: [Int32]

        public init(
            pids: [Int32] = [], footprintBytes: UInt64 = 0, residentBytes: UInt64 = 0,
            unreadablePids: [Int32] = []
        ) {
            self.pids = pids
            self.footprintBytes = footprintBytes
            self.residentBytes = residentBytes
            self.unreadablePids = unreadablePids
        }
    }

    /// PURE. Sums per-pid usage over a caller-supplied pid list.
    ///
    /// Split out so the summation — including the "unreadable is not zero"
    /// rule — is testable without any live process.
    static func treeUsage(pids: [Int32], usage: (Int32) -> (footprint: UInt64, resident: UInt64)?)
        -> TreeUsage
    {
        var result = TreeUsage()
        for pid in pids {
            guard let one = usage(pid) else {
                result.unreadablePids.append(pid)
                continue
            }
            result.pids.append(pid)
            result.footprintBytes += one.footprint
            result.residentBytes += one.resident
        }
        return result
    }

    /// Sums `proc_pid_rusage` over `rootPid` **and every descendant** in
    /// `snapshot`.
    ///
    /// ⚠️ **The tree, never the pidfile pid.** `scripts/ace-step/run.sh` ends
    /// `exec uv run --no-sync acestep-api`, so the pid the pidfile records is the
    /// `uv` supervisor and a *separate* python child holds the weights
    /// (m23-bb recorded the topology as `pid 49156 -> python 49160`). Asking
    /// `ps`/`rusage` about the pidfile pid alone is where the famous "RSS reports
    /// ~1 GB for a ~75 GB hold" reading most likely comes from.
    /// `scripts/rvc/run.sh` `exec`s its python directly and has no such split,
    /// which is exactly why a pairwise special case would be wrong.
    ///
    /// Internal, not public: its parameter type `SidecarProcessDiscovery.Snapshot`
    /// is internal to this module, and the only consumer
    /// (`ModelLifecycleCoordinator`) is in this module too.
    static func treeUsage(rootPid: Int32, snapshot: SidecarProcessDiscovery.Snapshot) -> TreeUsage {
        let pids = [rootPid] + snapshot.descendants(of: rootPid).map(\.pid)
        return treeUsage(pids: pids, usage: processUsage(of:))
    }

    /// IMPURE. `proc_pid_rusage(RUSAGE_INFO_V4)` for one pid, or nil when it
    /// fails. Measured: succeeds for same-uid pids (including foreign ones),
    /// fails for root-owned pids.
    static func processUsage(of pid: Int32) -> (footprint: UInt64, resident: UInt64)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return nil }
        return (footprint: info.ri_phys_footprint, resident: info.ri_resident_size)
    }

    // MARK: - Formatting (pure; every refusal message goes through here)

    /// Bytes as GB, one decimal, in the units the refusal messages and
    /// Activity Monitor both speak (10^9, not 2^30 — the user reconciles this
    /// figure against Activity Monitor, which uses GB).
    public static func formatGB(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    /// Signed variant for deltas, which may legitimately be negative.
    public static func formatGB(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
}
