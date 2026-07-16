import Foundation

/// m18-b: main-actor wedge liveness. The engine watchdog (DAWEngine's
/// `EngineWatchdog`) covers a stalled RENDER side; a wedged MAIN ACTOR was
/// invisible — the control socket keeps accepting frames (all transport runs
/// on the server's private queue) while EVERY routed command silently hangs on
/// the `Task { @MainActor }` hop. This file is the detection story:
///
/// · `MainActorLiveness` — the pure, headless state machine (the
///   EngineWatchdog precedent: injected time, no wall clock, every rule
///   testable without sleeps). Pings are posted to the main actor; a pong is
///   the main actor answering. An unanswered ping older than
///   `wedgeThresholdSeconds` = wedged; the FIRST pong = recovered, with the
///   total wedge duration retained for reporting.
/// · `MainActorLivenessMonitor` — the thin app wiring: a background
///   DispatchSourceTimer posts main-actor pings, a lock-protected mailbox
///   records pongs, and `snapshot()` gives ANY thread (the control server's
///   queue tier, the debug seam) a Sendable read without touching the main
///   actor. Breadcrumbs go to ~/Library/Logs/DAWPro/main-actor-wedge.log,
///   written OFF-main (a wedged main thread can't draw — and shouldn't be
///   asked to log its own hang).
///
/// DETECTION AND HONESTY ONLY: no auto-kill, no auto-restart. The engine and
/// render thread run right through a main-actor wedge (that independence is a
/// feature); the monitor never touches them.

/// One Sendable read of the monitor's state — what the control server's queue
/// tier consults before every MainActor hop, and what the `debug.mainActorWedge`
/// bare read echoes.
public struct MainActorLivenessSnapshot: Sendable, Equatable {
    /// False while an unanswered ping is older than the wedge threshold.
    public var responsive: Bool
    /// How long the main actor has been unresponsive, measured from the OLDEST
    /// unanswered ping (so it includes the threshold run-up). Non-nil iff
    /// `responsive` is false.
    public var wedgedForSeconds: Double?
    /// Lifetime ping/pong counters (pings posted to the main actor / answers
    /// recorded). During a wedge `pingsSent` runs ahead of `pongsReceived`.
    public var pingsSent: Int
    public var pongsReceived: Int
    /// Total duration of the most recent COMPLETED wedge (first missed ping →
    /// recovery pong). Retained after recovery — nonzero forever means "the
    /// main actor wedged and recovered at least once this session".
    public var lastWedgeDurationSeconds: Double?
    /// The configured detection threshold, echoed for discoverability.
    public var wedgeThresholdSeconds: Double

    public init(responsive: Bool, wedgedForSeconds: Double?, pingsSent: Int,
                pongsReceived: Int, lastWedgeDurationSeconds: Double?,
                wedgeThresholdSeconds: Double) {
        self.responsive = responsive
        self.wedgedForSeconds = wedgedForSeconds
        self.pingsSent = pingsSent
        self.pongsReceived = pongsReceived
        self.lastWedgeDurationSeconds = lastWedgeDurationSeconds
        self.wedgeThresholdSeconds = wedgeThresholdSeconds
    }
}

/// The pure state machine. All time is injected (`now` is any monotonic
/// seconds value — the monitor feeds it mach uptime); nothing here sleeps,
/// schedules, or reads a clock.
public struct MainActorLiveness: Sendable, Equatable {

    public enum State: Sendable, Equatable {
        case responsive
        /// `forSeconds` counts from the OLDEST unanswered ping — the honest
        /// "how long has the main actor not run" measure.
        case wedged(forSeconds: Double)
    }

    /// Edge transitions for the breadcrumb writer. `check(now:)` latches
    /// `becameWedged` (fired once per wedge); `recordPong(now:)` fires
    /// `recovered` iff a wedge had been latched.
    public enum Transition: Sendable, Equatable {
        case becameWedged(unresponsiveForSeconds: Double)
        case recovered(totalWedgeSeconds: Double)
    }

    /// A pong overdue by more than this = wedged. 2.5 s sits in the middle of
    /// the defensible 2–3 s band: with the monitor's 1 s ping cadence, a real
    /// wedge is declared at the first timer tick past ~2.5 s of silence
    /// (≤ ~3.5 s worst case), while a merely busy main actor (sync project
    /// load, a long layout pass) almost never trips it.
    public static let defaultWedgeThresholdSeconds = 2.5

    public let wedgeThresholdSeconds: Double

    public private(set) var pingsSent = 0
    public private(set) var pongsReceived = 0
    public private(set) var lastWedgeDurationSeconds: Double?
    /// Send time of the oldest ping still awaiting its pong. nil = nothing
    /// outstanding (the main actor answered everything we asked).
    private var oldestUnansweredPingAt: Double?
    /// The `becameWedged` latch — set by `check(now:)`, cleared by the
    /// recovery pong. Keeps the breadcrumb to ONE line per wedge.
    private var wedgeDeclared = false

    public init(wedgeThresholdSeconds: Double = MainActorLiveness.defaultWedgeThresholdSeconds) {
        self.wedgeThresholdSeconds = wedgeThresholdSeconds
    }

    /// A ping was posted to the main actor at `now`. Only the FIRST ping of an
    /// outstanding run anchors the wedge clock — later pings queued behind it
    /// must not make the wedge look younger than it is.
    public mutating func recordPing(now: Double) {
        pingsSent += 1
        if oldestUnansweredPingAt == nil { oldestUnansweredPingAt = now }
    }

    /// The main actor ran a ping task at `now`. ANY pong proves the main actor
    /// is alive RIGHT NOW, so the whole outstanding run clears (pings queued
    /// during a wedge all flush within the same main-actor turn anyway).
    /// Returns `.recovered` iff a wedge had been declared.
    public mutating func recordPong(now: Double) -> Transition? {
        pongsReceived += 1
        defer { oldestUnansweredPingAt = nil }
        guard wedgeDeclared else { return nil }
        wedgeDeclared = false
        let total = now - (oldestUnansweredPingAt ?? now)
        lastWedgeDurationSeconds = total
        return .recovered(totalWedgeSeconds: total)
    }

    /// The timer-tick edge detector: latches and returns `.becameWedged` the
    /// first time `state(now:)` crosses into wedged; nil on every later tick
    /// of the same wedge (and always nil while responsive).
    public mutating func check(now: Double) -> Transition? {
        guard case .wedged(let seconds) = state(now: now), !wedgeDeclared else { return nil }
        wedgeDeclared = true
        return .becameWedged(unresponsiveForSeconds: seconds)
    }

    /// Pure read — wedged iff the oldest unanswered ping is STRICTLY older
    /// than the threshold. Independent of `check` so a queue-tier snapshot
    /// sees the wedge at frame time, not at tick granularity.
    public func state(now: Double) -> State {
        guard let anchor = oldestUnansweredPingAt, now - anchor > wedgeThresholdSeconds else {
            return .responsive
        }
        return .wedged(forSeconds: now - anchor)
    }

    public func snapshot(now: Double) -> MainActorLivenessSnapshot {
        let wedgedFor: Double?
        switch state(now: now) {
        case .responsive: wedgedFor = nil
        case .wedged(let seconds): wedgedFor = seconds
        }
        return MainActorLivenessSnapshot(
            responsive: wedgedFor == nil,
            wedgedForSeconds: wedgedFor,
            pingsSent: pingsSent,
            pongsReceived: pongsReceived,
            lastWedgeDurationSeconds: lastWedgeDurationSeconds,
            wedgeThresholdSeconds: wedgeThresholdSeconds)
    }

    // MARK: - Breadcrumb lines (pure formatters, tested headless)

    /// The wedge-declared breadcrumb. Written OFF-main the moment the wedge is
    /// latched (the main thread is, by definition, unavailable to log it).
    public static func wedgeLine(unresponsiveForSeconds: Double,
                                 thresholdSeconds: Double,
                                 timestamp: Date = Date()) -> String {
        "\(iso8601(timestamp)) WEDGED main actor unresponsive for "
            + String(format: "%.1f", unresponsiveForSeconds)
            + " s (threshold " + String(format: "%.1f", thresholdSeconds) + " s)"
    }

    /// The recovery breadcrumb, with the TOTAL wedge duration.
    public static func recoveryLine(totalWedgeSeconds: Double,
                                    timestamp: Date = Date()) -> String {
        "\(iso8601(timestamp)) RECOVERED main actor responsive again after "
            + String(format: "%.1f", totalWedgeSeconds) + " s wedged"
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// The app-side wiring: owns the ping timer (background queue), the pong
/// mailbox (lock-protected `MainActorLiveness`), and the breadcrumb sink.
///
/// @unchecked Sendable justification: `liveness` — the only mutable state
/// shared across tiers — is accessed exclusively under `lock` (timer ticks on
/// `timerQueue`, pongs from main-actor tasks, `snapshot()` from any thread,
/// including the control server's queue). `timer` is only touched inside
/// `start()`/`stop()`, which the owning AppModel calls from the main actor;
/// every other stored property is a `let` of Sendable type.
public final class MainActorLivenessMonitor: @unchecked Sendable {

    /// 1 s cadence: cheap (one no-op main-actor task per second) and fine
    /// enough that the 2.5 s threshold detects within ~3.5 s worst case.
    public static let defaultPingIntervalSeconds = 1.0

    private let lock = NSLock()
    private var liveness: MainActorLiveness
    private let clock: @Sendable () -> Double
    private let breadcrumb: @Sendable (String) -> Void
    private let pingIntervalSeconds: Double
    private let timerQueue = DispatchQueue(label: "dawpro.main-actor-liveness")
    private var timer: DispatchSourceTimer?

    /// - Parameters:
    ///   - wedgeThresholdSeconds / pingIntervalSeconds: detection constants
    ///     (injected for tests; the defaults are the shipped behavior).
    ///   - clock: monotonic seconds. The default is mach uptime
    ///     (`DispatchTime`), which pauses across system sleep — so a lid-close
    ///     mid-ping can never masquerade as a wedge (the EngineWatchdog
    ///     no-wall-time law).
    ///   - breadcrumb: where transition lines go; defaults to appending to
    ///     ~/Library/Logs/DAWPro/main-actor-wedge.log.
    public init(
        wedgeThresholdSeconds: Double = MainActorLiveness.defaultWedgeThresholdSeconds,
        pingIntervalSeconds: Double = MainActorLivenessMonitor.defaultPingIntervalSeconds,
        clock: @escaping @Sendable () -> Double = {
            Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        },
        breadcrumb: (@Sendable (String) -> Void)? = nil
    ) {
        self.liveness = MainActorLiveness(wedgeThresholdSeconds: wedgeThresholdSeconds)
        self.pingIntervalSeconds = pingIntervalSeconds
        self.clock = clock
        self.breadcrumb = breadcrumb ?? Self.defaultBreadcrumbSink()
    }

    /// Starts the ping timer. Idempotent; call from the owner (main actor).
    public func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: timerQueue)
        source.schedule(deadline: .now() + pingIntervalSeconds,
                        repeating: pingIntervalSeconds,
                        leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.handleTimerTick() }
        source.resume()
        timer = source
    }

    /// Cancels the ping timer. Call from the owner (main actor).
    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Sendable read for any tier — never touches the main actor.
    public func snapshot() -> MainActorLivenessSnapshot {
        let now = clock()
        lock.lock()
        defer { lock.unlock() }
        return liveness.snapshot(now: now)
    }

    /// One timer tick (on `timerQueue`): record + edge-check under the lock,
    /// write the wedge breadcrumb OFF-main if this tick latched one, then post
    /// the main-actor ping. Internal (not private) so tests can drive ticks
    /// directly with an injected clock — no wall time, no sleeps.
    func handleTimerTick() {
        let now = clock()
        lock.lock()
        liveness.recordPing(now: now)
        let transition = liveness.check(now: now)
        let threshold = liveness.wedgeThresholdSeconds
        lock.unlock()
        if case .becameWedged(let seconds) = transition {
            breadcrumb(MainActorLiveness.wedgeLine(
                unresponsiveForSeconds: seconds, thresholdSeconds: threshold))
        }
        Task { @MainActor [weak self] in self?.recordPong() }
    }

    /// The pong: the main actor ran our task. Nonisolated on purpose — it only
    /// takes the lock and (on recovery) hops the breadcrumb back OFF-main.
    /// Internal for the same injected-clock testability as `handleTimerTick`.
    func recordPong() {
        let now = clock()
        lock.lock()
        let transition = liveness.recordPong(now: now)
        lock.unlock()
        if case .recovered(let total) = transition {
            // Recovery line off-main too (house rule: the monitor never does
            // work on the main thread beyond the no-op ping itself).
            let sink = breadcrumb
            timerQueue.async { sink(MainActorLiveness.recoveryLine(totalWedgeSeconds: total)) }
        }
    }

    /// The default breadcrumb sink: append-a-line to
    /// ~/Library/Logs/DAWPro/main-actor-wedge.log (directory created on first
    /// write). Failures are swallowed — a diagnostics writer must never take
    /// the app down, and there is no one to report to during a wedge.
    static func defaultBreadcrumbSink() -> @Sendable (String) -> Void {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DAWPro/main-actor-wedge.log")
        return { line in
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            let data = Data((line + "\n").utf8)
            if fm.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
