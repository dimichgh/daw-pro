import DAWCore
import Foundation

/// M9 crash-c: the engine stall detector. The engine can no longer die
/// silently — while the engine claims to be running, the perf-b telemetry
/// heartbeat (the lifetime-monotone render-callback counter every
/// instrumented strip stamps; the device pulls ALL nodes continuously while
/// running, live-thru, so a stopped transport is NOT idle) must advance
/// every check window. Frozen across `stallThreshold` consecutive checks
/// means the render side is dead (HAL stall, device death without a
/// configuration-change notification, wedged engine), and the watchdog
/// drives the injected `restart` — in the real engine, the SAME recovery
/// routine the configuration-change path uses.
///
/// TICK-DRIVEN, NO WALL CLOCK: the state machine only ever moves in
/// `tick()` (the AutosaveManager/injected-seam precedent) — `AudioEngine`
/// owns the timer loop, tests drive ticks directly, so every rule here is
/// headless-testable and interval-independent by construction.
///
/// READER-SIDE ONLY: `heartbeat` snapshots an atomic cell, `isEngineRunning`
/// reads main-actor bookkeeping, `restart` runs control-plane recovery.
/// Nothing here touches the render thread.
///
/// Known accepted imprecision (documented, not fixed): a concurrent OFFLINE
/// render bumps the same shared telemetry context, which can only DELAY
/// stall detection (the heartbeat keeps advancing) — never false-positive.
@MainActor
final class EngineWatchdog {

    /// Consecutive frozen-heartbeat checks (while running) that declare a
    /// stall. 2 checks × the caller's interval (default 2 s) ≈ 4 s
    /// worst-case detection.
    static let stallThreshold = 2

    /// Consecutive failed restart attempts after which the watchdog gives
    /// up (`.failed`) and stops retrying — no thrash loop against a dead
    /// device. Only `reset()` (a later successful external engine start)
    /// re-arms it.
    static let maxConsecutiveFailures = 3

    /// Reader for the lifetime-monotone heartbeat (render-callback count).
    private let heartbeat: () -> Int
    /// Reader for "the engine claims to be running AND the heartbeat signal
    /// is expected" — the arming condition. An intentionally stopped engine
    /// is NOT a stall.
    private let isEngineRunning: () -> Bool
    /// The recovery routine. Throwing = a failed attempt (counted toward
    /// `maxConsecutiveFailures`); returning = the engine is back up.
    private let restart: () throws -> Void

    private(set) var state: EngineWatchdogStatus.State = .idle
    private(set) var restartCount = 0
    private(set) var consecutiveFailures = 0
    private(set) var lastHeartbeat = 0
    /// Consecutive ticks the heartbeat sat frozen while running.
    private(set) var frozenStreak = 0

    init(heartbeat: @escaping () -> Int,
         isEngineRunning: @escaping () -> Bool,
         restart: @escaping () throws -> Void) {
        self.heartbeat = heartbeat
        self.isEngineRunning = isEngineRunning
        self.restart = restart
    }

    /// One watchdog check. Rules (the crash-c contract):
    /// · `.failed` is STICKY — checked first, before anything else, so a
    ///   given-up watchdog never restarts again (not even through a
    ///   stop/start observed here) until `reset()` re-arms it. This is the
    ///   no-busy-retry law; the "not running → idle" rule below is for
    ///   normal operation only.
    /// · Not running → streak resets, state `.idle` (intentional stop ≠ stall).
    /// · Running + heartbeat advanced → `.ok`, streak and failure count reset.
    /// · Running + heartbeat frozen → streak +1; at `stallThreshold` the
    ///   stall is declared (`.recovering`) and `restart` is invoked — once
    ///   per tick while the stall persists, success → `.ok` + `restartCount`
    ///   +1, throw → `consecutiveFailures` +1 until `.failed`.
    func tick() {
        let beat = heartbeat()
        defer { lastHeartbeat = beat }

        // Sticky give-up: manual intervention (or an external successful
        // start, which calls reset()) is the only way out.
        if state == .failed { return }

        guard isEngineRunning() else {
            frozenStreak = 0
            state = .idle
            return
        }

        if beat != lastHeartbeat {
            // Render side alive: everything re-arms.
            frozenStreak = 0
            consecutiveFailures = 0
            state = .ok
            return
        }

        frozenStreak += 1
        guard frozenStreak >= Self.stallThreshold else { return }

        // Stall declared: heartbeat frozen while the engine claims to run.
        state = .recovering
        do {
            try restart()
            restartCount += 1
            consecutiveFailures = 0
            frozenStreak = 0
            state = .ok
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures >= Self.maxConsecutiveFailures {
                state = .failed
            }
        }
    }

    /// Re-arms the watchdog after a successful external engine start
    /// (`AudioEngine.prepare()` calls this once the hardware is up): clears
    /// the give-up state, streak, and failure count. `restartCount` is a
    /// LIFETIME self-heal count and deliberately survives — nonzero forever
    /// means "the engine died and recovered at least once this session".
    func reset() {
        state = .idle
        frozenStreak = 0
        consecutiveFailures = 0
    }

    /// Snapshot for the wire. `engineRunning` is supplied by the caller (the
    /// engine's own `isRunning` claim) — deliberately NOT this watchdog's
    /// armed view, which also folds in whether a heartbeat is expected.
    func status(engineRunning: Bool) -> EngineWatchdogStatus {
        EngineWatchdogStatus(
            state: state, restartCount: restartCount,
            consecutiveFailures: consecutiveFailures,
            lastHeartbeat: lastHeartbeat, engineRunning: engineRunning)
    }
}
