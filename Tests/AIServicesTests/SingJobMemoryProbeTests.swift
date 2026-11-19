import Darwin
import Foundation
import Testing
@testable import AIServices
@testable import DAWCore

// W8-X6F N1 (W8-RV6 review N1): the peak memory of a 3-part styled job, measured, not modelled. It runs ONLY when
// `X6F_MEMPROBE=1` is in the environment, and its numbers mean something only in a process that runs nothing else
// (`./scripts/test.sh --filter <this test's exact name>`): both instruments read PROCESS-WIDE counters, which other
// suites' threads move (the m23-ab-2 lesson, `InsertSpectrumTapTests.swift:34`). It asserts nothing about the size:
// it prints one `X6F-N1` line for the lane's report.
//
// Instrument 1, RESIDENT: `rusage_info_v4.ri_lifetime_max_phys_footprint` (the kernel's peak footprint of the whole
// process) minus `ri_phys_footprint` when the job starts. Instrument 2, ALLOCATED: the highest
// `malloc_zone_statistics(nil).size_in_use` a 1 ms sampler thread saw, minus the same at the start.

/// Samples allocated bytes every millisecond on its own thread until stopped.
final class X6FMallocSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var peak = 0

    static func inUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    func start() {
        let thread = Thread { [self] in
            while true {
                let now = Self.inUse()
                lock.lock()
                if now > peak { peak = now }
                let go = running
                lock.unlock()
                if !go { return }
                usleep(1_000)
            }
        }
        thread.start()
    }

    func stop() -> Int {
        lock.lock()
        running = false
        let value = peak
        lock.unlock()
        return value
    }
}

enum X6FFootprint {
    /// (current footprint, lifetime peak footprint) of this process, bytes; nil when the call fails.
    static func read() -> (current: UInt64, peak: UInt64)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return nil }
        return (info.ri_phys_footprint, info.ri_lifetime_max_phys_footprint)
    }
}

@Suite("SingJob N1 memory probe (W8-X6F; X6F_MEMPROBE=1 only)")
struct SingJobMemoryProbeTests {

    static let enabled = ProcessInfo.processInfo.environment["X6F_MEMPROBE"] == "1"
    /// Phrases of 8 one-beat notes every 12 beats (120 BPM: 4 s sung, 2 s rest).
    static let phrases = 30

    @Test("N1 probe: a 3-part styled job's peak memory above its start (lead + third above + double)",
          .enabled(if: SingJobMemoryProbeTests.enabled))
    func threePartStyledJobPeak() async throws {
        let onsets = (0..<Self.phrases).flatMap { k in (0..<8).map { Double(12 * k + $0) } }
        let lyrics = Array(repeating: "one two three four five six seven eight", count: Self.phrases)
            .joined(separator: "\n")
        // `X6F_LOWPASS` smooths the fake tracker (see `DetectorSpy.lowPass`; default 2, so the job lands). With 0 the
        // raw tracker fails gate L2 on airy takes (as W8-X6 measured), the job ends failed, and this test reds; the
        // peak is the same either way (MEASURED by W8-X6F: 9.9 L allocated before the fix, 5.9 L after, both ways).
        let lowPass = Int(ProcessInfo.processInfo.environment["X6F_LOWPASS"] ?? "2") ?? 2
        let h = try await SingPartsHarness.make("x6f-memprobe", lyrics: lyrics, onsets: onsets, lowPass: lowPass)
        defer { h.cleanup() }
        try await MainActor.run {
            for t in h.store.tracks.indices {
                if let c = h.store.tracks[t].clips.firstIndex(where: { $0.id == h.clipID }) {
                    h.store.tracks[t].clips[c].singStyle = SingStyle(vibrato: .wide, air: 1)
                    return
                }
            }
            throw ProjectError.clipNotFound(h.clipID)
        }
        let request = SingJobRequest(clipID: h.clipID, parts: [SingJobPartsTests.thirdAbove, SingJobPart(.double)],
                                     key: SingJobPartsTests.cMajor)

        let start = try #require(X6FFootprint.read())
        let sampler = X6FMallocSampler()
        let allocatedStart = X6FMallocSampler.inUse()
        sampler.start()
        let done = try await h.run(request)
        let allocatedPeak = sampler.stop()
        let end = try #require(X6FFootprint.read())

        let seconds = Double(onsets.max() ?? 0) / 2 + 1 + 0.24
        let lBytes = Int(seconds * 24_000 * 4)
        let mb = { (bytes: Double) in String(format: "%.1f", bytes / 1_048_576) }
        let resident = Double(end.peak) - Double(start.current)
        let allocated = Double(allocatedPeak - allocatedStart)
        print("X6F-N1 lowPass=\(lowPass) phase=\(done.phase.rawValue) parts=\(done.parts?.map(\.state.rawValue) ?? []) "
              + "codes=\(done.parts?.map { $0.error?.code ?? "-" } ?? []) job=\(done.error?.code ?? "-") "
              + "L=\(mb(Double(lBytes)))MB "
              + "resident_peak_above_start=\(mb(resident))MB (\(String(format: "%.2f", resident / Double(lBytes))) L) "
              + "allocated_peak_above_start=\(mb(allocated))MB (\(String(format: "%.2f", allocated / Double(lBytes))) L) "
              + "footprint_start=\(mb(Double(start.current)))MB lifetime_peak_before=\(mb(Double(start.peak)))MB "
              + "lifetime_peak_after=\(mb(Double(end.peak)))MB")
        #expect(done.phase == .done, "\(done.error?.message ?? "")")
        #expect(end.peak > start.peak, "the job raised the process's peak, so the peak is the job's")
    }
}
