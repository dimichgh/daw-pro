import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M9 crash-c: the engine watchdog state machine, pinned headless through
/// its injected readers (no wall clock inside — pure tick logic, so every
/// rule is interval-independent by construction). No fake-stall hooks exist
/// in the production engine; a "stall" here is simply a harness whose
/// heartbeat stops advancing.
@MainActor
@Suite("Engine watchdog state machine (M9 crash-c)")
struct EngineWatchdogStateMachineTests {

    /// Injected-reader harness: the test IS the engine.
    @MainActor
    private final class Harness {
        var beat = 0
        var running = true
        var restartShouldThrow = false
        private(set) var restartCalls = 0
        /// What a successful restart does to the "engine": by default the
        /// heartbeat resumes advancing (a healed render side).
        var onRestartSuccess: (() -> Void)?

        private(set) lazy var dog = EngineWatchdog(
            heartbeat: { [unowned self] in beat },
            isEngineRunning: { [unowned self] in running },
            restart: { [unowned self] in
                restartCalls += 1
                if restartShouldThrow { throw ProjectError.engineUnavailable }
                onRestartSuccess?()
            })
    }

    @Test("advancing heartbeat while running: ok forever, zero restarts")
    func advancingHeartbeatStaysOK() {
        let h = Harness()
        for _ in 0..<10 {
            h.beat += 7   // any advance counts; magnitude is irrelevant
            h.dog.tick()
            #expect(h.dog.state == .ok)
            #expect(h.dog.frozenStreak == 0)
        }
        #expect(h.restartCalls == 0)
        #expect(h.dog.restartCount == 0)
        #expect(h.dog.consecutiveFailures == 0)
        #expect(h.dog.lastHeartbeat == h.beat)
    }

    @Test("frozen ×2 while running: exactly ONE restart, restartCount 1, back to ok")
    func frozenTwiceRestartsOnce() {
        let h = Harness()
        h.beat = 42
        h.dog.tick()                       // advancing → ok
        #expect(h.dog.state == .ok)

        h.dog.tick()                       // frozen ×1 — below threshold
        #expect(h.restartCalls == 0)
        #expect(h.dog.frozenStreak == 1)
        #expect(h.dog.state == .ok)        // not yet declared

        h.onRestartSuccess = { h.beat += 1 }  // recovery heals the heartbeat
        h.dog.tick()                       // frozen ×2 — stall declared
        #expect(h.restartCalls == 1)
        #expect(h.dog.state == .ok)        // successful restart lands back in ok
        #expect(h.dog.restartCount == 1)
        #expect(h.dog.consecutiveFailures == 0)
        #expect(h.dog.frozenStreak == 0)

        // Healed heartbeat keeps it ok — no second restart.
        h.beat += 5
        h.dog.tick()
        #expect(h.restartCalls == 1)
        #expect(h.dog.state == .ok)
    }

    @Test("frozen while NOT running: idle, never restarts (intentional stop ≠ stall)")
    func stoppedEngineNeverRestarts() {
        let h = Harness()
        h.running = false
        for _ in 0..<6 {
            h.dog.tick()                   // heartbeat frozen throughout
            #expect(h.dog.state == .idle)
        }
        #expect(h.restartCalls == 0)
        #expect(h.dog.restartCount == 0)
    }

    @Test("a stop mid-streak resets the streak: the stall must re-prove itself")
    func stopResetsStreak() {
        let h = Harness()
        h.beat = 10
        h.dog.tick()                       // ok
        h.dog.tick()                       // frozen ×1
        #expect(h.dog.frozenStreak == 1)

        h.running = false
        h.dog.tick()                       // intentional stop wipes the streak
        #expect(h.dog.state == .idle)
        #expect(h.dog.frozenStreak == 0)

        h.running = true
        h.dog.tick()                       // frozen ×1 again — NOT a stall yet
        #expect(h.restartCalls == 0)
        h.dog.tick()                       // frozen ×2 — now it is
        #expect(h.restartCalls == 1)
    }

    @Test("restart throwing ×3: recovering → failed, and NO 4th attempt (no thrash loop)")
    func threeFailuresGiveUp() {
        let h = Harness()
        h.restartShouldThrow = true
        h.beat = 5
        h.dog.tick()                       // ok
        h.dog.tick()                       // frozen ×1
        h.dog.tick()                       // frozen ×2 → attempt 1 throws
        #expect(h.restartCalls == 1)
        #expect(h.dog.state == .recovering)
        #expect(h.dog.consecutiveFailures == 1)

        h.dog.tick()                       // still frozen → attempt 2 throws
        #expect(h.restartCalls == 2)
        #expect(h.dog.state == .recovering)

        h.dog.tick()                       // attempt 3 throws → give up
        #expect(h.restartCalls == 3)
        #expect(h.dog.state == .failed)
        #expect(h.dog.consecutiveFailures == 3)

        // Sticky: no further attempts, running or not — until reset().
        for _ in 0..<4 { h.dog.tick() }
        h.running = false
        h.dog.tick()
        h.running = true
        h.dog.tick()
        #expect(h.restartCalls == 3)
        #expect(h.dog.state == .failed)
    }

    @Test("a success mid-failure-run clears the failure count")
    func successClearsFailures() {
        let h = Harness()
        h.restartShouldThrow = true
        h.beat = 9
        h.dog.tick()                       // ok
        h.dog.tick()                       // frozen ×1
        h.dog.tick()                       // attempt 1 throws
        h.dog.tick()                       // attempt 2 throws
        #expect(h.dog.consecutiveFailures == 2)

        h.restartShouldThrow = false       // device came back
        h.onRestartSuccess = { h.beat += 1 }
        h.dog.tick()                       // attempt 3 SUCCEEDS
        #expect(h.dog.state == .ok)
        #expect(h.dog.restartCount == 1)
        #expect(h.dog.consecutiveFailures == 0)
    }

    @Test("an advancing heartbeat also clears a pending failure count")
    func heartbeatAdvanceClearsFailures() {
        let h = Harness()
        h.restartShouldThrow = true
        h.beat = 3
        h.dog.tick()                       // ok
        h.dog.tick()                       // frozen ×1
        h.dog.tick()                       // attempt 1 throws (cf 1)
        #expect(h.dog.consecutiveFailures == 1)

        h.beat += 1                        // render side woke up on its own
        h.dog.tick()
        #expect(h.dog.state == .ok)
        #expect(h.dog.consecutiveFailures == 0)
        #expect(h.restartCalls == 1)       // no further attempt needed
    }

    @Test("reset() re-arms a failed watchdog; restartCount survives as lifetime history")
    func resetRearms() {
        let h = Harness()
        // One successful self-heal first (restartCount 1)…
        h.beat = 1
        h.dog.tick()
        h.dog.tick()
        h.onRestartSuccess = { h.beat += 1 }
        h.dog.tick()
        #expect(h.dog.restartCount == 1)

        // …then a stall whose restarts all fail → failed.
        h.onRestartSuccess = nil
        h.restartShouldThrow = true
        h.dog.tick()                       // the heal's +1 lands: advanced → ok
        h.dog.tick()                       // frozen ×1
        h.dog.tick()                       // frozen ×2 → attempt throws (cf 1)
        h.dog.tick()                       // cf 2
        h.dog.tick()                       // cf 3 → failed
        #expect(h.dog.state == .failed)
        let callsAtGiveUp = h.restartCalls

        // reset() (the engine's successful external prepare()) re-arms.
        h.dog.reset()
        #expect(h.dog.state == .idle)
        #expect(h.dog.consecutiveFailures == 0)
        #expect(h.dog.restartCount == 1)   // lifetime count survives

        h.restartShouldThrow = false
        h.onRestartSuccess = { h.beat += 1 }
        h.dog.tick()                       // frozen ×1 (fresh streak)
        h.dog.tick()                       // frozen ×2 → restart again
        #expect(h.restartCalls == callsAtGiveUp + 1)
        #expect(h.dog.state == .ok)
        #expect(h.dog.restartCount == 2)
    }

    @Test("status(engineRunning:) mirrors the machine verbatim")
    func statusMirrorsState() {
        let h = Harness()
        h.beat = 11
        h.dog.tick()
        let status = h.dog.status(engineRunning: true)
        #expect(status.state == .ok)
        #expect(status.restartCount == 0)
        #expect(status.consecutiveFailures == 0)
        #expect(status.lastHeartbeat == 11)
        #expect(status.engineRunning)
        // engineRunning is caller-supplied truth, not the armed reader.
        #expect(!h.dog.status(engineRunning: false).engineRunning)
    }
}

/// M9 crash-c: the watchdog seams inside the real `AudioEngine` — the
/// heartbeat/arming readers, the `recoverEngine()` extraction contract, and
/// (device-gated, the `liveSmoke` idiom) the full `watchdogRestart()` path
/// against real hardware.
@MainActor
@Suite("Engine watchdog — AudioEngine wiring (M9 crash-c)")
struct EngineWatchdogEngineTests {

    @Test("a fresh engine reads the zero/idle status and ticks stay idle")
    func freshEngineIsIdle() {
        let engine = AudioEngine()
        #expect(engine.watchdogStatus() == .idle)
        // Ticks against a never-started engine never arm or restart.
        for _ in 0..<3 { engine.watchdogTick() }
        let status = engine.watchdogStatus()
        #expect(status.state == .idle)
        #expect(status.restartCount == 0)
        #expect(!status.engineRunning)
    }

    @Test("hasInstrumentedStrips census: false empty, true for every strip kind, false again after teardown")
    func instrumentedStripCensus() throws {
        let avEngine = AVAudioEngine()
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try avEngine.enableManualRenderingMode(.offline, format: format,
                                               maximumFrameCount: 512)
        let graph = PlaybackGraph(engine: avEngine)
        #expect(!graph.hasInstrumentedStrips)

        let busID = UUID()
        _ = graph.reconcile(tracks: [
            Track(name: "A", kind: .audio),
            Track(name: "Keys", kind: .instrument,
                  instrument: InstrumentDescriptor(kind: .testTone)),
            Track(id: busID, name: "Bus", kind: .bus),
        ])
        #expect(graph.hasInstrumentedStrips)

        _ = graph.reconcile(tracks: [])
        #expect(!graph.hasInstrumentedStrips)
    }

    @Test("recoverEngine without an anchor is the notification path's early-out: bin untouched, no restart")
    func recoverEngineWithoutAnchorIsEarlyOut() {
        // Extraction-fidelity pin: the config-change body's `guard let
        // anchor` early-return survived the crash-c extraction verbatim.
        // Build a parked retire-bin (stopped-after-run teardown, the crash-a
        // shape), then prove recoverEngine() leaves it alone when there is
        // no playback anchor — it may ONLY sync isRunning and return.
        let engine = AudioEngine()
        engine.tracksDidChange([Track(name: "A", kind: .audio)])
        engine.graph.engineHasRun = true   // exactly what prepare() sets
        engine.tracksDidChange([])         // teardown while "stopped after run"
        #expect(!engine.graph.pendingDetachNodes.isEmpty)

        engine.recoverEngine()
        #expect(!engine.graph.pendingDetachNodes.isEmpty)  // NOT flushed
        #expect(!engine.isRunning)                          // only synced
    }

    @Test("live: watchdogRestart bounces a playing engine through the shared recovery")
    func liveWatchdogRestart() async throws {
        let engine = AudioEngine()
        do {
            try engine.prepare()
        } catch {
            // Headless machine without an output device — the live half of
            // this path is covered by the state-machine suite plus the
            // extraction pins above (labeled gap, the liveSmoke idiom).
            return
        }

        engine.tracksDidChange([
            Track(name: "Keys", kind: .instrument,
                  clips: [Clip(name: "midi", startBeat: 0, lengthBeats: 64, notes: [
                      MIDINote(pitch: 69, velocity: 100, startBeat: 0, lengthBeats: 64),
                  ])],
                  instrument: InstrumentDescriptor(kind: .testTone)),
        ])

        var pushes: [Double] = []
        engine.playheadHandler = { pushes.append($0) }
        var transport = TransportState()
        transport.isPlaying = true
        engine.startPlayback(transport)
        try await Task.sleep(for: .milliseconds(250))

        // While playing, the heartbeat advances: one tick reads ok.
        engine.watchdogTick()
        #expect(engine.watchdogStatus().state == .ok)

        // The watchdog's actual restart closure, end to end: stop the
        // (perfectly healthy) engine underneath and drive the shared
        // recovery — the same routine a real stall triggers.
        try engine.watchdogRestart()
        #expect(engine.isRunning)
        #expect(engine.watchdogStatus().engineRunning)
        // The retire bin was drained against the restarted engine
        // (recoverEngine's crash-a flush).
        #expect(engine.graph.pendingDetachNodes.isEmpty)

        // Playback resumed through startPlayers: the playhead keeps moving.
        let pushesAtRestart = pushes.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(pushes.count > pushesAtRestart)

        // The healed engine keeps reading ok on later ticks.
        engine.watchdogTick()
        #expect(engine.watchdogStatus().state != .failed)

        engine.stopPlayback()
        engine.shutdown()
    }
}
