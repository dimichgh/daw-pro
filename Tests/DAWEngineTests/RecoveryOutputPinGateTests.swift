import AVFoundation
import AudioToolbox
import CoreAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m23-bt LIVE GATE — DOES THE OUTPUT-DEVICE PIN SURVIVE `recoverEngine()`?
//
// THE QUESTION, and why reasoning could not answer it. `recoverEngine()`
// restarts the engine (`if !engine.isRunning { engine.prepare(); try
// engine.start() }`) and does NOT call `reapplyOutputDevicePinIfNeeded()` —
// unlike `prepare()` (:688) and `rebuildEngine` (:1055), which both do. The
// m20-j implementer REASONED that `kAudioOutputUnitProperty_CurrentDevice`
// survives a same-object stop→start and said plainly it had not verified that.
// If the reasoning is wrong, a device change or a watchdog bounce silently
// returns the user's audio to the system default: no error, no notice, sound
// just leaves the interface they picked. That is a SILENT user-facing
// regression, which is why this is measured rather than argued.
//
// ⚠️ WHY A GREEN READ-BACK IS NOT AN ANSWER BY ITSELF — the hole this item
// found in `OutputDeviceLoopbackGateTests.pinSurvivesRateFlip`. That test looks
// like it covers this question. It does not: it sets up with `startTestTone`,
// which never sets `currentAnchor`, so its configuration change lands on
// `recoverEngine`'s `guard let anchor = currentAnchor else { return }`
// early-out and the restart block is never reached. It proves the pin survives
// a rate flip WHEN RECOVERY DOES NOTHING. A pin trivially survives a restart
// that did not happen. So every leg here proves the restart HAPPENED before it
// reads the pin, using three independent witnesses:
//
//   1. `recoveryRestartCountForTesting` — the restart BRANCH executed (0→1).
//      Deterministic and starvation-proof, unlike any timing measurement.
//   2. `outputNodeRenderSampleTimeForTesting` — the HARDWARE genuinely went
//      down and came back: a new render session's sample clock restarts near
//      zero, so `after < before` is a positive witness. (Corroborated in-tree
//      from the other side: m23-bq measured playhead freezes of 1045 / 2060 /
//      3063 ms against rolls of 1000 / 2000 / 3000 ms — a 1:1 line that only
//      arises if the new session restarts at ~0.)
//   3. `outputPinReapplyCountForTesting` — NOTHING re-applied the pin. This
//      closes the subtler confound: `watchdogRestart()` ends with
//      `if !isRunning { try prepare() }`, and `prepare()` DOES re-pin. So a
//      surviving pin could otherwise mean "recovery failed and prepare healed
//      it" rather than "the AUHAL kept it".
//
// THE MEASURED ANSWER (2026-08-02, this machine, BlackHole 2ch id 89 pinned,
// system default 77 "MacBook Pro Speakers"): **THE PIN SURVIVES.** The m20-j
// implementer's reasoning was CORRECT, and no production change was made.
//
//   LEG A (watchdogRestart mid-playback, the always-bounces route):
//     restarts 0 → 1          the restart branch really executed
//     reapplies 1 → 1         nothing re-applied the pin (no prepare fallthrough)
//     renderSampleTime 59904 → 1536   the hardware genuinely bounced
//     auhalDevice 89 → 89     THE ANSWER — the AUHAL kept the pinned device
//     unit 0x…0c2 → 0x…0c2    the SAME AudioUnit object, so there is no new AU
//                             that could have come up on the default
//     systemDefault 77 → 77   unmoved
//   LEG B (recoverEngine direct, the config-change alias): restarts 0 → 0 — the
//     engine was still running so the restart branch was SKIPPED, and the clock
//     advanced 1536 → 21504 rather than restarting, which corroborates it. Its
//     green pin read-back is a regression guard, NOT restart evidence.
//   LEG C: the AUHAL was knocked to 77 and read back 77 (the read-back
//     discriminates), and after a bounce it was STILL 77 —
//     `knockHealedByRecovery=false`. Recovery leaves the AUHAL exactly as it
//     found it; the pin holds because the AUHAL keeps its own property across a
//     same-object stop→start, not because anything restores it.
//
// MEASURED RED (the leg is not a leg until it has been seen fail): knocking the
// AUHAL to the system default immediately before LEG A's bounce fails it with
// `(after.device → 77) == (loopback.id → 89)`, while all three witnesses stay
// green (restarts 0→1, reapplies 1→1, clock 59904→1536) — so the red is the pin
// assertion specifically, not a sick fixture.
//
// ⚠️ WHAT THIS GATE DOES NOT PROVE. It is PROPERTY-LEVEL: the AUHAL reports the
// pinned device after the bounce. It does NOT prove audio still ARRIVES there —
// `OutputDeviceLoopbackGateTests`' header sets that standard ("a property can
// read back correctly while no audio reaches the hardware"), and m20-b measured
// `AudioUnitSetProperty` returning `noErr` on a discarded write. That gap is
// DELIBERATE and load-bearing, not an oversight: the fixture must be silent for
// LEG C's knock-to-default to be safe, and an audible leg would need a
// user-present moment. Do not close it by making this gate audible — add a
// separate opt-in leg to the loopback gate if it is ever wanted. Also measured
// on a VIRTUAL loopback only, and with the pin applied COLD (before `prepare()`).
//
// SAFETY — every leg is INAUDIBLE BY CONSTRUCTION, and that is what makes the
// negative control safe. The fixture rolls a transport with a REAL anchor but
// ZERO tracks (machine-checked via `lastTracksForTesting.isEmpty`), the
// metronome default is off, and no test tone is ever started — so the graph has
// no startable players and renders silence. Nothing can reach the user's
// speakers no matter where the AUHAL points, which is precisely why LEG C may
// deliberately knock the AUHAL onto the system default.
//
// SAFETY — devices. Nothing here WRITES any device setting (no nominal-rate
// write; contrast `pinSurvivesRateFlip`, which is why that one has its own env
// var). The system default output is READ ONLY, before and after every leg, and
// asserted UNMOVED. The only property this gate ever writes is THIS ENGINE'S
// OWN output AUHAL's `CurrentDevice` — app-local by construction. The user's
// real interfaces are never written and never opened by name.
//
// OPT-IN under its OWN env var:
//
//     DAWPRO_LIVE_RECOVERY_PIN=1 ./scripts/test.sh --filter RecoveryOutputPin
//
// Deliberately NOT `DAWPRO_LIVE_OUTPUT_LOOPBACK` — that var also enables two
// AUDIBLE legs that need a user-present moment and are consequently still
// unrun, and a verification gated behind a var nobody can run unattended is not
// a verification. Deliberately NOT `DAWPRO_LIVE_OUTPUT_RATEFLIP` either: that
// one writes a device setting and this one must not.
//
// ⚠️ `.serialized` IS LOAD-BEARING. There is one physical loopback device and
// access to it has to be serial — see the header of
// `OutputDeviceLoopbackGateTests` for what parallelism cost there. Note also
// m23-bu: parallel `@MainActor` suites starve the main actor badly enough that
// live TIMING legs false-green. Every assertion below is a property read-back
// or a counter, never a timing measurement, and it must stay that way.

@Suite("Recovery output-device pin (m23-bt live gate)", .serialized)
struct RecoveryOutputPinGateTests {

    // `nonisolated` because `@Test(.enabled(if:))` evaluates its trait from a
    // Sendable closure outside the main actor; the value is an immutable Bool.
    nonisolated static let isEnabled = ProcessInfo.processInfo
        .environment["DAWPRO_LIVE_RECOVERY_PIN"] == "1"

    /// Loopback UIDs this gate knows how to use, in preference order. Resolved
    /// BY UID at the moment of use — an `AudioDeviceID` is a transient handle
    /// that moves on every `coreaudiod` restart (m20-b measured BlackHole
    /// going 121 → 89 mid-session).
    nonisolated static let loopbackUIDs = ["BlackHole2ch_UID", "BlackHole16ch_UID"]

    // MARK: - Read-only probes

    /// This engine's output AUHAL's current device, read from OUTSIDE the
    /// engine — a read-back verified by the same code that wrote it proves
    /// less than one verified independently.
    @MainActor
    private static func auhalDevice(_ engine: AudioEngine) -> AudioDeviceID? {
        guard let unit = engine.outputNodeAudioUnitForTesting else { return nil }
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &deviceID, &size)
        return status == noErr ? deviceID : nil
    }

    /// Writes THIS ENGINE'S OWN AUHAL `CurrentDevice`. App-local: it is the same
    /// property `applyOutputDevicePin` writes, on the same unit. No device
    /// setting and no system default is touched.
    @MainActor
    @discardableResult
    private static func pointAUHAL(_ engine: AudioEngine, at device: AudioDeviceID) -> OSStatus {
        guard let unit = engine.outputNodeAudioUnitForTesting else { return OSStatus(-1) }
        var value = device
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global, 0, &value,
                                    UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    private static func describe(_ id: AudioDeviceID?) -> String {
        guard let id else { return "unreadable" }
        let name = OutputDevices.enumerate()
            .first { OutputDevices.deviceID(forUID: $0.uid) == id }?.name
        return "\(id)" + (name.map { " (\($0))" } ?? "")
    }

    /// Everything worth knowing about the engine at one instant.
    private struct Probe {
        let restarts: Int
        let reapplies: Int
        let renderSampleTime: AVAudioFramePosition?
        let device: AudioDeviceID?
        let unit: AudioUnit?
        let systemDefault: AudioDeviceID?
        let selection: [String]

        var rendered: String {
            "restarts=\(restarts) reapplies=\(reapplies)"
                + " renderSampleTime=" + (renderSampleTime.map(String.init) ?? "nil")
                + " auhalDevice=" + RecoveryOutputPinGateTests.describe(device)
                + " unit=" + (unit.map { String(describing: $0) } ?? "nil")
                + " systemDefault=" + RecoveryOutputPinGateTests.describe(systemDefault)
                + " selection=\(selection)"
        }
    }

    @MainActor
    private static func probe(_ engine: AudioEngine) -> Probe {
        Probe(restarts: engine.recoveryRestartCountForTesting,
              reapplies: engine.outputPinReapplyCountForTesting,
              renderSampleTime: engine.outputNodeRenderSampleTimeForTesting,
              device: auhalDevice(engine),
              unit: engine.outputNodeAudioUnitForTesting,
              systemDefault: OutputDevices.defaultOutputDeviceID(),
              selection: engine.availableOutputDevices().filter(\.isSelected).map(\.uid))
    }

    // MARK: - The silent fixture

    /// A rolling transport with a REAL `currentAnchor` and NO audio.
    ///
    /// The anchor is the whole point: `recoverEngine()` early-returns unless
    /// `currentAnchor != nil`, so a stopped transport never reaches the restart
    /// block at all — that is exactly the early-out `pinSurvivesRateFlip` runs
    /// into. `startPlayers` sets `currentAnchor` UNCONDITIONALLY, before and
    /// independently of anything the graph schedules, so an empty project rolls
    /// a genuine anchor while rendering silence.
    ///
    /// Returns nil on a machine with no usable output device (headless CI) —
    /// `try #require` would FAIL there, and a machine fact is not a defect.
    @MainActor
    private static func startSilentRoll(pinnedTo uid: String) -> AudioEngine? {
        let engine = AudioEngine()
        do {
            try engine.setOutputDevice(uid: uid)
            try engine.prepare()
        } catch {
            engine.shutdown()
            return nil
        }
        // No `tracksDidChange` at all: nothing to schedule, no startable
        // players, and the metronome default is off (`TransportState`'s
        // `isMetronomeEnabled` defaults to false).
        var transport = TransportState()
        transport.isPlaying = true
        engine.startPlayback(transport)
        return engine
    }

    /// Machine-checked silence precondition. Argued silence is not measured
    /// silence, and the negative control's safety rests on this.
    @MainActor
    private static func requireSilentFixture(_ engine: AudioEngine) {
        let noTracks = "the fixture must have NO tracks — a leg that can make sound is not "
            + "safe to point at the system default"
        #expect(engine.lastTracksForTesting.isEmpty, "\(noTracks)")
        #expect(!engine.isTonePlaying, "the fixture must never start a test tone")
    }

    /// Polls the render clock until `until` holds or the budget runs out.
    /// Returns the final reading and how long the wait took.
    ///
    /// ⚠️ The wait is NOT decoration. Immediately after a restart the output
    /// node still reports the PREVIOUS session's `lastRenderTime` with its
    /// valid flags set (that staleness IS the m23-bq defect), so a reader who
    /// does not wait for the new session's first callback measures the bug
    /// instead of the bounce.
    @MainActor
    private static func awaitRenderClock(
        _ engine: AudioEngine, budgetSeconds: Double = 3.0,
        until: (AVAudioFramePosition?) -> Bool
    ) async throws -> (value: AVAudioFramePosition?, waitedMs: Double) {
        let start = Date()
        var value = engine.outputNodeRenderSampleTimeForTesting
        while !until(value), Date().timeIntervalSince(start) < budgetSeconds {
            try await Task.sleep(for: .milliseconds(25))
            value = engine.outputNodeRenderSampleTimeForTesting
        }
        return (value, Date().timeIntervalSince(start) * 1000)
    }

    /// How long the fixture rolls before the bounce.
    ///
    /// ⚠️ LOAD-BEARING FOR THE CLOCK WITNESS'S MARGIN, not a "let it settle"
    /// nicety. The witness is `sampleTimeAfter < sampleTimeBefore`, and the NEW
    /// session climbs past the old session's last value after exactly this much
    /// wall time. The first run of this file measured `before = 2048` frames
    /// (~43 ms at 48 kHz) with a 25 ms poll — a 43 ms window to catch the new
    /// session in, which m23-bu's main-actor starvation could easily overshoot
    /// and turn into a SPURIOUS RED blamed on the engine. Rolling ~1.2 s first
    /// makes `before` ~57 600 frames, so the poll has ~1.2 s of margin instead
    /// of 43 ms. Do not shorten this to speed the suite up.
    private static let preBounceRollMs = 1_200

    /// Resolves the loopback, or nil with a printed reason. Never fails:
    /// "BlackHole is not installed" is a machine fact, not a defect.
    private static func resolveLoopback() -> (uid: String, id: AudioDeviceID)? {
        guard let device = OutputDevices.enumerate()
            .first(where: { loopbackUIDs.contains($0.uid) }) else {
            print("[measured] m23-bt SKIPPED: no loopback output device installed "
                  + "(this gate needs BlackHole 2ch)")
            return nil
        }
        guard let id = OutputDevices.deviceID(forUID: device.uid) else {
            print("[measured] m23-bt SKIPPED: '\(device.uid)' enumerated but would not "
                  + "resolve to a live AudioDeviceID")
            return nil
        }
        if device.isDefault {
            print("[measured] m23-bt SKIPPED: the loopback IS the system default — "
                  + "pinning to it would prove nothing")
            return nil
        }
        return (device.uid, id)
    }

    // MARK: - LEG A — the watchdog route (always bounces)

    /// THE LEG THAT ANSWERS THE ITEM. `watchdogRestart()` stops the engine
    /// FIRST and then calls `recoverEngine()`, so with a rolling anchor the
    /// restart branch is guaranteed to execute — the maximal-stress route, and
    /// the one a silent HAL stall actually takes in production.
    @MainActor
    @Test("live: the output pin survives a watchdog bounce mid-playback",
          .enabled(if: RecoveryOutputPinGateTests.isEnabled))
    func pinSurvivesWatchdogRestartMidPlayback() async throws {
        guard let loopback = Self.resolveLoopback() else { return }
        guard let engine = Self.startSilentRoll(pinnedTo: loopback.uid) else {
            print("[measured] m23-bt SKIPPED: no usable output device (prepare threw)")
            return
        }
        defer { engine.shutdown() }
        Self.requireSilentFixture(engine)

        // Let the render session come up, then prove the clock is LIVE and
        // ADVANCING. Without this the "after < before" witness would be
        // comparing against a number that never moves, and a clock that never
        // moves cannot distinguish a bounce from a stall.
        let (first, firstWaitMs) = try await Self.awaitRenderClock(engine) { $0 != nil }
        guard let firstValue = first else {
            print("[measured] m23-bt SKIPPED: the render clock never became valid "
                  + "(waited \(Int(firstWaitMs)) ms) — no bounce witness is possible")
            return
        }
        let (secondOpt, advanceWaitMs) = try await Self.awaitRenderClock(engine) {
            ($0 ?? firstValue) > firstValue
        }
        // Roll on, so the old session's clock is far enough along that catching
        // the new one below has a wide margin — see `preBounceRollMs`.
        try await Task.sleep(for: .milliseconds(Self.preBounceRollMs))
        let before = Self.probe(engine)
        print("[measured] m23-bt LEG-A BEFORE \(before.rendered)"
              + " clockValidAfterMs=\(Int(firstWaitMs))"
              + " firstSample=\(firstValue) advancedTo=" + (secondOpt.map(String.init) ?? "nil")
              + " advanceWaitMs=\(Int(advanceWaitMs))")

        let frozen = "the render clock never ADVANCED while rolling (\(firstValue) → "
            + (secondOpt.map(String.init) ?? "nil") + ") — a frozen clock cannot witness a "
            + "bounce, so nothing below would mean anything"
        #expect((secondOpt ?? firstValue) > firstValue, "\(frozen)")

        let notPinned = "the pin did not take BEFORE the bounce (read "
            + "\(Self.describe(before.device)), wanted \(Self.describe(loopback.id))) — "
            + "nothing below would mean anything"
        #expect(before.device == loopback.id, "\(notPinned)")

        // THE BOUNCE.
        try engine.watchdogRestart()

        // Wait for the NEW session's first callback: the clock must fall BELOW
        // where the old session had got to.
        let beforeSample = before.renderSampleTime ?? firstValue
        let (afterClock, bounceWaitMs) = try await Self.awaitRenderClock(engine) {
            guard let value = $0 else { return false }
            return value < beforeSample
        }
        let after = Self.probe(engine)
        print("[measured] m23-bt LEG-A AFTER  \(after.rendered)"
              + " bounceWaitMs=\(Int(bounceWaitMs))"
              + " clockBefore=\(beforeSample) clockAfter=" + (afterClock.map(String.init) ?? "nil"))

        // WITNESS 1 — the restart BRANCH executed.
        let noRestart = "recoverEngine did NOT take its restart branch (restarts "
            + "\(before.restarts) → \(after.restarts)). A pin trivially survives a restart "
            + "that never happened — this is the exact hole m23-bt found in "
            + "pinSurvivesRateFlip, and without this witness the read-back below is worthless"
        #expect(after.restarts == before.restarts + 1, "\(noRestart)")

        // WITNESS 2 — the HARDWARE bounced: a new render session, clock restarted.
        let noBounce = "the render clock did not restart across the bounce (\(beforeSample) → "
            + (afterClock.map(String.init) ?? "nil") + "). Either the hardware never went "
            + "down, or the new session had not rendered a callback within the budget — "
            + "either way the read-back is not evidence about a real restart"
        #expect((afterClock ?? Int64.max) < beforeSample, "\(noBounce)")

        // WITNESS 3 — NOTHING re-applied the pin, so a surviving pin survived
        // ON ITS OWN. This excludes the `watchdogRestart` → `prepare()`
        // fallthrough, which re-pins at :688 and would otherwise HEAL a lost
        // pin and present it as a survival.
        let healed = "something re-applied the output pin during the bounce (reapplies "
            + "\(before.reapplies) → \(after.reapplies)) — most likely recovery failed and "
            + "watchdogRestart fell through to prepare(). The pin read-back below then says "
            + "nothing about surviving a restart"
        #expect(after.reapplies == before.reapplies, "\(healed)")

        // THE ANSWER.
        let lost = "m23-bt: THE OUTPUT PIN WAS LOST ACROSS AN ENGINE RECOVERY. The AUHAL now "
            + "points at \(Self.describe(after.device)), the pin was "
            + "\(Self.describe(loopback.id)). This is the silent user-facing regression the "
            + "item was filed for: the user's audio has returned to the system default with "
            + "no error and no notice. Fix by calling reapplyOutputDevicePinIfNeeded() inside "
            + "recoverEngine's `if !engine.isRunning` block, BETWEEN engine.prepare() and "
            + "try engine.start() — the same slot and the same reason as prepare():688"
        #expect(after.device == loopback.id, "\(lost)")

        // The engine's own view must agree with the hardware.
        let claim = "the engine still claims \(after.selection) as the selection"
        #expect(after.selection == [loopback.uid], "\(claim)")

        // And the property m20-j's "SYSTEM DEFAULT UNMOVED" leg exists to
        // protect: a pin that survives while the system default got dragged
        // along is a DIFFERENT bug wearing the same green.
        let moved = "the system default output MOVED across the recovery "
            + "(\(Self.describe(before.systemDefault)) → "
            + "\(Self.describe(after.systemDefault))) — DAW Pro must never write it"
        #expect(after.systemDefault == before.systemDefault, "\(moved)")
    }

    // MARK: - LEG B — the configuration-change route (restart is CONDITIONAL)

    /// `handleConfigurationChange()` is a verbatim one-line alias for
    /// `recoverEngine()`, so this is the device-flip route.
    ///
    /// ⚠️ ITS RESTART IS CONDITIONAL. Driven directly, without a preceding
    /// `engine.stop()`, a healthy engine is still running, so `if
    /// !engine.isRunning` is FALSE and no restart happens. A green pin
    /// read-back on that branch is VACUOUS as evidence about restart survival.
    /// So this leg asserts WHICH branch ran, from the same witnesses, and
    /// labels its conclusion accordingly rather than reporting a blind green.
    @MainActor
    @Test("live: recoverEngine (config-change route) — which branch ran, and the pin after it",
          .enabled(if: RecoveryOutputPinGateTests.isEnabled))
    func configChangeRoutePinOutcome() async throws {
        guard let loopback = Self.resolveLoopback() else { return }
        guard let engine = Self.startSilentRoll(pinnedTo: loopback.uid) else {
            print("[measured] m23-bt SKIPPED: no usable output device (prepare threw)")
            return
        }
        defer { engine.shutdown() }
        Self.requireSilentFixture(engine)

        let (first, _) = try await Self.awaitRenderClock(engine) { $0 != nil }
        guard let firstValue = first else {
            print("[measured] m23-bt LEG-B SKIPPED: the render clock never became valid")
            return
        }
        _ = try await Self.awaitRenderClock(engine) { ($0 ?? firstValue) > firstValue }
        let before = Self.probe(engine)
        print("[measured] m23-bt LEG-B BEFORE \(before.rendered)")
        #expect(before.device == loopback.id, "the pin did not take before the recovery")

        engine.recoverEngine()

        // Give any new session a chance to render before reading.
        try await Task.sleep(for: .milliseconds(400))
        let after = Self.probe(engine)
        let restarted = after.restarts > before.restarts
        print("[measured] m23-bt LEG-B AFTER  \(after.rendered)"
              + " restartBranchRan=\(restarted)")

        if restarted {
            print("[measured] m23-bt LEG-B: the restart branch RAN — this leg IS "
                  + "restart-survival evidence on this run")
            #expect(after.reapplies == before.reapplies,
                    "something re-applied the pin on the config-change route")
        } else {
            print("[measured] m23-bt LEG-B: the restart branch did NOT run (the engine was "
                  + "still running, which is `recoverEngine`'s documented behaviour for a "
                  + "healthy engine). The pin read-back below is a REGRESSION GUARD, not "
                  + "restart-survival evidence — LEG A carries that.")
            // Prove that is what happened rather than asserting it from belief:
            // an un-bounced session's clock keeps advancing, it does not restart.
            let clockAfter = after.renderSampleTime ?? 0
            let clockBefore = before.renderSampleTime ?? 0
            let disagree = "the restart counter says no restart happened, but the render "
                + "clock went BACKWARDS (\(clockBefore) → \(clockAfter)) — the two witnesses "
                + "disagree and neither can be trusted"
            #expect(clockAfter >= clockBefore, "\(disagree)")
        }

        let lost = "the output pin was lost on the configuration-change route — the AUHAL now "
            + "points at \(Self.describe(after.device)), the pin was "
            + "\(Self.describe(loopback.id))"
        #expect(after.device == loopback.id, "\(lost)")
        #expect(after.selection == [loopback.uid], "the engine's own selection changed")
        #expect(after.systemDefault == before.systemDefault,
                "the system default output MOVED across the recovery")
    }

    // MARK: - LEG C — the read-back can go RED

    /// A live leg that has never been seen red is worthless (the lesson m23-bq
    /// paid for). This deliberately knocks THIS ENGINE'S OWN AUHAL onto the
    /// system default and confirms the read-back reports it — proving the
    /// read-back discriminates rather than printing a constant.
    ///
    /// It then bounces and reports what the bounce did to the knock. That
    /// second half is REPORTED, not asserted, on purpose: what it should read
    /// depends on whether recovery re-applies the pin, which is the very thing
    /// under test — an assertion there would silently invert the day the fix
    /// lands, and a leg that must be rewritten to stay green is a maintenance
    /// trap, not a control.
    ///
    /// SAFE because the fixture is silent: `requireSilentFixture` machine-
    /// checks that there are no tracks and no test tone, so pointing the engine
    /// at the system default cannot make a sound.
    @MainActor
    @Test("live: the pin read-back can go RED — knock the AUHAL to the system default",
          .enabled(if: RecoveryOutputPinGateTests.isEnabled))
    func readBackDiscriminatesAndCanGoRed() async throws {
        guard let loopback = Self.resolveLoopback() else { return }
        guard let systemDefault = OutputDevices.defaultOutputDeviceID() else {
            print("[measured] m23-bt LEG-C SKIPPED: no system default output device")
            return
        }
        guard let engine = Self.startSilentRoll(pinnedTo: loopback.uid) else {
            print("[measured] m23-bt SKIPPED: no usable output device (prepare threw)")
            return
        }
        defer { engine.shutdown() }
        Self.requireSilentFixture(engine)

        let (first, _) = try await Self.awaitRenderClock(engine) { $0 != nil }
        let firstValue = first ?? 0
        _ = try await Self.awaitRenderClock(engine) { ($0 ?? firstValue) > firstValue }
        let pinned = Self.probe(engine)
        print("[measured] m23-bt LEG-C PINNED \(pinned.rendered)")
        #expect(pinned.device == loopback.id, "the pin did not take")

        // THE KNOCK — this engine's own AUHAL only. No device setting, no
        // system default write.
        let status = Self.pointAUHAL(engine, at: systemDefault)
        try await Task.sleep(for: .milliseconds(300))
        let knocked = Self.probe(engine)
        print("[measured] m23-bt LEG-C KNOCKED status=\(status) \(knocked.rendered)")

        // THE CONTROL: the read-back reports the NEW device. This is what makes
        // every `#expect(after.device == loopback.id)` above capable of failing.
        let refused = "the AUHAL refused the knock (OSStatus \(status)) — the negative "
            + "control did not run, so no leg here has been shown able to fail"
        #expect(status == noErr, "\(refused)")

        let constant = "the read-back did not follow the knock (reads "
            + "\(Self.describe(knocked.device)), knocked to \(Self.describe(systemDefault))) "
            + "— a read-back that reports a CONSTANT would make every green in this file "
            + "meaningless"
        #expect(knocked.device == systemDefault, "\(constant)")
        #expect(knocked.device != loopback.id,
                "the read-back still reports the loopback after being pointed elsewhere")

        // REPORTED, NOT ASSERTED — see the doc comment.
        try engine.watchdogRestart()
        try await Task.sleep(for: .milliseconds(600))
        let bounced = Self.probe(engine)
        let knockHealed = bounced.device == loopback.id
        print("[measured] m23-bt LEG-C AFTER-BOUNCE \(bounced.rendered)"
              + " knockHealedByRecovery=\(knockHealed)"
              + " (true ⇒ something in the recovery path re-applies the pin;"
              + " false ⇒ recovery leaves the AUHAL exactly as it found it)")

        #expect(bounced.systemDefault == pinned.systemDefault,
                "the system default output MOVED — DAW Pro must never write it")

        // Leave the engine on its pin regardless of the outcome above.
        Self.pointAUHAL(engine, at: loopback.id)
    }
}
