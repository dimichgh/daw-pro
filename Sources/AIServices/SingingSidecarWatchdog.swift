import Darwin
import Dispatch
import Foundation
import os

/// The singing sidecar's runaway watchdog (item p2-sing-c — design
/// `docs/design/2026-09-27-p2-sing-integration.md` §2.6). **It cleans up; it is not an admission
/// gate** — the same "let it fail if this happens, but still good to clean it up" scope cut
/// `ModelAdmission`'s own doc comment records for the whole lifecycle feature (m23-dl).
///
/// While the sidecar is resident, it samples the sidecar TREE's `phys_footprint` (never the
/// pidfile pid alone — `ModelMemory.treeUsage`'s own doc explains why) at a configurable interval
/// (4 Hz in production) and SIGKILLs the tree, pid-exact, when either:
///   * the footprint passes the configured cap (16 GiB in production; **INJECTABLE** — tests use a
///     512 MB cap against the stub's `SING_STUB_FAULT=balloon` 600 MB growth, design §9's gate);
///   * system memory pressure reads Critical on 2 CONSECUTIVE samples (a single blip never kills).
///
/// ## Why an epoch, never `Task.cancel()`
///
/// `ModelLifecycleCoordinator.cancelIdleUnload`'s doc records a MEASURED, reproducible crash:
/// cancelling a `Task` while it is suspended in the real `Task.sleep`, under this exact build
/// (package Swift 6 + `-enable-testing`, swift-testing runner), aborts the process out of the
/// Swift concurrency runtime. This type's sampling loop has the identical shape (a detached `Task`
/// parked in `sleepSeconds` between samples), so it inherits the SAME rule: `disarm()` never calls
/// `.cancel()`. It revokes an epoch instead; the loop notices on its next wake (after `sleepSeconds`
/// returns) and returns without touching anything. An orphaned loop iteration costs nothing beyond
/// the sleep it was already in.
actor SingingSidecarWatchdog {

    /// Everything the loop needs, injected so every test drives it without a real timer, a real
    /// process tree, or (**never**, on a machine shared by other lanes) real system memory
    /// pressure.
    struct Configuration: Sendable {
        var capBytes: UInt64
        var pollIntervalSeconds: Double
        /// Real default: `ModelMemory.treeUsage(rootPid:snapshot:)` over a fresh
        /// `SidecarProcessDiscovery.captureSnapshot()`. `nil` means "could not be read" (e.g. the
        /// pid is already gone) and is treated as under the cap — there is nothing to kill.
        var sampleFootprintBytes: @Sendable (Int32) -> UInt64?
        /// Real default reads a long-lived `DispatchSource` observer's last-known level — see
        /// `MemoryPressureObserver` below. **UNVERIFIED against genuine Critical pressure** (see
        /// that type's doc and `$S/w7/SC/REVIEW-REQUEST.md`); every test injects a scripted fake.
        var readMemoryPressureCritical: @Sendable () -> Bool
        var sleepSeconds: @Sendable (Double) async -> Void
        /// The actual OS-level action once `decide` says kill — a plain, synchronous, pure-effect
        /// closure (no actor hop needed: it is `SingingSidecarWatchdog.killTree`, which owns no
        /// state of its own). `recordSample` has already stored the human reason in
        /// `lastKillReason` before this runs, so the manager reconciles ITS OWN bookkeeping later,
        /// lazily, by reading that property — never by this closure calling back into the manager
        /// (which would need `self` captured before `init` finishes; see `SingingSidecarManager`'s
        /// doc for why that reconcile-on-read design was chosen instead).
        var kill: @Sendable (Int32, String) -> Void

        init(
            capBytes: UInt64,
            pollIntervalSeconds: Double = 0.25,
            sampleFootprintBytes: @escaping @Sendable (Int32) -> UInt64? = SingingSidecarWatchdog.liveFootprintBytes,
            readMemoryPressureCritical: @escaping @Sendable () -> Bool = { false },
            sleepSeconds: @escaping @Sendable (Double) async -> Void = { seconds in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            },
            kill: @escaping @Sendable (Int32, String) -> Void = { pid, _ in
                SingingSidecarWatchdog.killTree(rootPid: pid)
            }
        ) {
            self.capBytes = capBytes
            self.pollIntervalSeconds = pollIntervalSeconds
            self.sampleFootprintBytes = sampleFootprintBytes
            self.readMemoryPressureCritical = readMemoryPressureCritical
            self.sleepSeconds = sleepSeconds
            self.kill = kill
        }
    }

    private let configuration: Configuration
    private var armedEpoch: UInt64?
    private var epochCounter: UInt64 = 0
    /// Most-recent-last; only the last two ever matter (`decide`'s "2 consecutive" rule).
    private var recentCritical: [Bool] = []
    /// Set right before `configuration.kill` is invoked — read by tests, and by the manager's own
    /// bookkeeping closure, to explain why the process is gone.
    private(set) var lastKillReason: String?
    /// Total samples taken, across every arming — the anti-vacuity check: a test asserting "no
    /// kill" must also prove the loop actually ran, or an inert loop and a correct one look alike.
    private(set) var samplesTaken: UInt64 = 0

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Arms sampling for `rootPid`. Any previous arming is revoked first (never cancelled — see
    /// the type doc).
    func arm(rootPid: Int32) {
        disarm()
        epochCounter &+= 1
        let epoch = epochCounter
        armedEpoch = epoch
        recentCritical = []
        lastKillReason = nil
        let config = configuration
        Task.detached { [weak self] in
            await SingingSidecarWatchdog.loop(rootPid: rootPid, epoch: epoch, config: config, owner: self)
        }
    }

    /// Revokes the current epoch. The loop notices on its next wake and returns.
    func disarm() {
        armedEpoch = nil
    }

    /// Clears a PREVIOUS boot's kill record. Called by the manager at the start of every new
    /// `start()` attempt, BEFORE spawning — without this, `lastKillReason` from a watchdog kill
    /// two boots ago would still read back as the current boot's classification until this one
    /// is itself armed (which only happens once it reaches `.healthy`), a real staleness window.
    func clearLastKillReason() {
        lastKillReason = nil
    }

    var isArmed: Bool { armedEpoch != nil }

    private func stillArmed(_ epoch: UInt64) -> Bool { armedEpoch == epoch }

    /// Records one sample and returns the decision. Actor-isolated so `recentCritical` and
    /// `samplesTaken` are never touched from two samples at once.
    private func recordSample(footprintBytes: UInt64?, critical: Bool) -> SingingWatchdogAction {
        samplesTaken &+= 1
        recentCritical.append(critical)
        if recentCritical.count > 2 { recentCritical.removeFirst(recentCritical.count - 2) }
        let action = Self.decide(
            footprintBytes: footprintBytes, capBytes: configuration.capBytes,
            recentCritical: recentCritical)
        if case .kill(let reason) = action { lastKillReason = reason }
        return action
    }

    private static func loop(
        rootPid: Int32, epoch: UInt64, config: Configuration, owner: SingingSidecarWatchdog?
    ) async {
        while true {
            await config.sleepSeconds(config.pollIntervalSeconds)
            guard let owner else { return }
            guard await owner.stillArmed(epoch) else { return }
            let footprint = config.sampleFootprintBytes(rootPid)
            let critical = config.readMemoryPressureCritical()
            let action = await owner.recordSample(footprintBytes: footprint, critical: critical)
            switch action {
            case .ok:
                continue
            case .kill(let reason):
                config.kill(rootPid, reason)
                await owner.disarm()
                return
            }
        }
    }

    // MARK: - The pure decision

    /// PURE. `recentCritical`'s last two entries must BOTH be true for a pressure kill — a single
    /// Critical blip never fires (design §2.6: "2 consecutive samples"). The footprint cap needs
    /// only one sample over it: it is a hard number, not a debounced signal.
    static func decide(
        footprintBytes: UInt64?, capBytes: UInt64, recentCritical: [Bool]
    ) -> SingingWatchdogAction {
        if let footprintBytes, footprintBytes > capBytes {
            return .kill(
                reason: "the sidecar tree's memory footprint reached "
                    + ModelMemory.formatGB(footprintBytes) + ", over the "
                    + ModelMemory.formatGB(capBytes) + " cap")
        }
        let lastTwo = recentCritical.suffix(2)
        if lastTwo.count == 2 && lastTwo.allSatisfy({ $0 == true }) {
            return .kill(reason: "system memory pressure read Critical on 2 consecutive samples")
        }
        return .ok
    }

    // MARK: - Real (impure) samplers — never exercised by a test

    /// IMPURE. The tree's `phys_footprint`, via the SAME internal helper the coordinator's own
    /// diagnostics use (`ModelMemory.treeUsage(rootPid:snapshot:)`), over a fresh process-table
    /// snapshot. `nil` only when the snapshot could not be taken at all; a dead or unreadable pid
    /// naturally reports ~0 bytes, which is safely under any real cap.
    nonisolated static func liveFootprintBytes(rootPid: Int32) -> UInt64? {
        let snapshot = SidecarProcessDiscovery.captureSnapshot()
        return ModelMemory.treeUsage(rootPid: rootPid, snapshot: snapshot).footprintBytes
    }

    /// IMPURE. Immediate SIGKILL of `rootPid` and every descendant captured BEFORE signalling (the
    /// m23-az-1 rule: a child whose parent has already died is reparented to pid 1 and the linkage
    /// is gone). Unlike `SidecarStop.terminateTree` there is no grace period and no identity
    /// re-check: the watchdog only ever acts on a pid the manager itself is tracking as the
    /// sidecar it spawned, and a runaway process is exactly the case where waiting out a graceful
    /// SIGTERM window is the wrong trade.
    nonisolated static func killTree(rootPid: Int32) {
        let snapshot = SidecarProcessDiscovery.captureSnapshot()
        for descendant in snapshot.descendants(of: rootPid) {
            kill(descendant.pid, SIGKILL)
        }
        kill(rootPid, SIGKILL)
    }
}

enum SingingWatchdogAction: Sendable, Equatable {
    case ok
    case kill(reason: String)
}

// MARK: - The real Critical-pressure observer

/// A long-lived `DispatchSource` memory-pressure observer (item p2-sing-c).
///
/// ⚠️ **`DispatchSource.makeMemoryPressureSource` is EVENT-DRIVEN, not a synchronous "ask now"
/// API** — there is no documented way to read the CURRENT level without first registering and
/// resuming a source and waiting for its handler to fire at least once. So this type does the
/// only architecturally correct thing: register ONCE for all three levels (`.normal`, `.warning`,
/// `.critical` — not `.critical` alone, or a later RETURN to normal would never clear a
/// previously-observed Critical reading), keep the source alive, and mirror its last-known level
/// into a lock-protected box that `readCritical()` polls synchronously.
///
/// ⚠️⚠️ **UNVERIFIED.** This has never observed a genuine Critical signal in this session:
/// forcing real system-wide memory pressure on a machine shared by ~12 other lanes was refused as
/// a standing-constraint risk (never run memory/CPU work that could destabilise another lane's
/// build). Its correctness rests on reading Apple's documented event-driven contract correctly,
/// not on empirical observation — see `$S/w7/SC/REVIEW-REQUEST.md`. Before the last-known level
/// has ever been set (no event has fired since `start()`), `readCritical()` reports `false`: the
/// conservative default, since a machine that has never told us it is under pressure should not be
/// treated as though it has.
final class MemoryPressureObserver: @unchecked Sendable {
    private let box = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var source: (any DispatchSourceMemoryPressure)?

    func start() {
        guard source == nil else { return }
        let queue = DispatchQueue(label: "com.dawpro.sing.watchdog.pressure")
        let newSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: queue)
        let box = self.box
        newSource.setEventHandler { [weak newSource] in
            guard let newSource else { return }
            box.withLock { $0 = newSource.data.contains(.critical) }
        }
        newSource.resume()
        source = newSource
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    func readCritical() -> Bool { box.withLock { $0 } }
}
