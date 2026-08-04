import AVFAudio
import CoreAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m23-bs-2 LEGS L1–L4 — THE ANCHOR LINE MUST SURVIVE A RECOVERY.
//
// ⚠️ WHICH LEG CARRIES THE REGRESSION GUARD (design §9.2, in those words):
// THE PROPERTY ASSERTION CARRIES IT. `RecoveryPlayheadTests` BECOMES
// CORROBORATION. The property seam proves the two anchor lines coincide; it
// must NEVER be loosened — if it fails, the engine is wrong. The timing leg
// proves the coinciding lines correspond to something audible; it MAY be
// loosened freely. If it flakes under full-suite load, loosen the TIMING leg,
// never the property assertion.
//
// THE DEFECT (m23-bs, measured by bs-1 2026-08-02). `recoverEngine` derived its
// resume beat from the host clock at ENTRY and then anchored the new schedule at
// `now + lead` — after `stopAllPlayers`, an optional engine restart, a parameter
// restore and a full schedule pass. Everything that work cost was time the
// transport never accounted for, so it stepped BACKWARD by 0.079 s (one clip,
// no engine bounce) to 0.215 s (realistic project, watchdog). The decomposition:
// the anchor LEAD is ~75 % of it, segment A 0.2–48 ms, segment B ~1 %, and a
// ~14 ms residual that is the render clock's lead over the host clock (δ).
//
// THE FIX. `AudioEngine.StartAnchorPolicy` — the caller either chose the beat
// (`.asSoonAsPractical`, relocation) or wall time chose it (`.atHostTime`,
// continuation). `recoverEngine` now predicts the instant `H` its anchor will
// land on, derives the resume beat FOR `H` off the outgoing anchor's line, and
// passes both. `startBeats` and `anchorHostTime` therefore become two views of
// ONE chosen number instead of two independent readings.
//
// WHY THE WITNESS IS A PROPERTY AND NOT A TIMING MEASUREMENT — this is the
// reusable insight of the item and it is not obvious. m23-bu-1 established that
// the seconds-scale delays under full-suite load are Swift-runtime SCHEDULING
// latency, not OS-level CPU starvation: a plain DispatchSourceTimer stayed at
// 18–98 ms across three full-suite runs while main-actor gaps hit
// 1803 / 3783 / 4218 ms. The two witnesses sit on OPPOSITE SIDES of that
// finding:
//
//   RecoveryPlayheadTests' lag metric  depends on the playhead Task being
//                                      SCHEDULED at 30 Hz  → the seconds-scale
//                                      channel (3 pushes where 36 are nominal)
//   this file's anchor-line property   depends on the synchronous straight-line
//                                      EXECUTION of recoverEngine → the
//                                      queue-jitter channel, tens of ms
//
// `recoverEngine` → `startPlayers` → `startAllPlayers` is one uninterrupted
// synchronous block with no await points, so once it is executing on the main
// actor only the OS preempts it. bs-1 tested that falsifiable claim and it
// held: full-suite segment B measured 0.4–20.2 ms (median 0.7), which is
// OS-jitter-class. So this file is trustworthy in exactly the regime where the
// timing leg is not. It is also ROLL-DURATION-INDEPENDENT: a Task.sleep that
// resumes 17 s late (measured, ROADMAP:548) changes nothing, because the
// identity holds between two anchors however long the roll was.
//
// ⚠️ THE SKIP IS ITSELF A COVERAGE HOLE UNLESS BOUNDED. L1 skips when the
// engine reports a budget overrun — a machine fact, not a defect. A degenerate
// implementation (horizon ≡ 0) would overrun EVERY time and skip EVERY time,
// passing forever while testing nothing. L2 (never skipped) and L3 (a pure
// read-back starvation cannot touch) are what close that.
//
// ⚠️ FORBIDDEN, and a reader WILL want it: an in-engine anchor-DIFFERENCE seam.
// Under this fix it recomputes the fix's own expression and subtracts it from
// itself — identically zero by algebra, so it reads GREEN against a broken
// TempoMap, a wrong loop branch or a sign error. It does redden on the obvious
// mutant, which is exactly the trap. The arithmetic is done TEST-SIDE here,
// against `anchorLineForTesting`'s raw pair, with this file's own closed form.
//
// ⚠️ `hasSampleAnchor` IS NOT READ HERE and must not be. It has exactly ONE
// consumer by design (m23-bq, machine-asserted by `RenderClockTrustSiteTests`).
// δ is printed and both cases tolerated.
//
// CONTENTION (design §13.8). These legs are declared in an EXTENSION of
// `RecoveryPlayheadTests` so they belong to that `.serialized` suite —
// VERIFIED, not assumed: the first filtered run printed all five tests under
// "Recovery playhead — stale render clock (m23-bq)" with no interleaving. Three
// live sessions are added here and six are removed by env-gating
// `RecoveryCostSplitTests`, so a default full run performs FEWER live playback
// sessions than before bs-2, which is the condition behind the
// `GaplessLoopTransportTests` flake. ⚠️ Scope honestly: this removes contention
// WITHIN this suite only — `GaplessLoopTransportTests` still runs in parallel.
//
// MUTANTS RUN AND MEASURED (filtered, 2026-08-02 — see the numbers in
// `docs/ROADMAP.md`'s m23-bs-2 close record):
//
//   (a) revert recoverEngine to entry-derivation  → L1 RED, 0.264 beats vs
//                                                   ε — a ~10^12x margin
//   (b) move the count read below stopAllPlayers  → L3 RED (engine 0 vs
//                                                   snapshot 1), L1 GREEN
//   (c) horizon ≡ 0                              → L3 RED, L1 SKIPPED (loudly)
//   (d) clamp unconditional (no forward clamp)    → NOTHING reddens, by design
//   (e) derive inside startPlayers                → L4 RED, L1 GREEN
//
// (b) and (e) reddening a DIFFERENT leg from (a) is the point of having four:
// a wrong budget and a wrong derivation are different defects and a suite that
// cannot tell them apart cannot direct the fix. (d) is a NULL result on
// purpose — it proves this file does not falsely claim to cover the past-anchor
// case, which is prevented by construction rather than by test.

extension RecoveryPlayheadTests {

    // MARK: - Shared reading

    /// One (beat, host instant) pair — the raw anchor line. The engine never
    /// computes a difference between two of these; this file does.
    struct AnchorLine {
        let beats: Double
        let host: UInt64
    }

    /// Everything one bounce produces, read as raw scalars.
    struct Continuity {
        let before: AnchorLine
        let after: AnchorLine
        let restartsBefore: Int
        let restartsAfter: Int
        let overrunCount: Int
        let overrunSeconds: Double
        let clampDownCount: Int
        let horizonSeconds: Double
        let playerCount: Int
        let snapshotCount: Int
        /// The silent gap: `stopAllPlayers` return → the new anchor instant.
        /// PRINTED, never asserted (§13.7): the gap is `A_after_stop + horizon`,
        /// bs-2 does not touch A, and L3 pins the horizon EXACTLY — so a
        /// threshold here could only catch what an exact read-back already
        /// catches, at the cost of a guessed millisecond bound.
        let gapSeconds: Double

        /// Elapsed wall time between the two anchor instants.
        var deltaSeconds: Double {
            after.host >= before.host
                ? AVAudioTime.seconds(forHostTime: after.host - before.host)
                : -AVAudioTime.seconds(forHostTime: before.host - after.host)
        }

        var rendered: String {
            "b0=" + String(format: "%.6f", before.beats)
                + " b1=" + String(format: "%.6f", after.beats)
                + " dt=" + String(format: "%.4f", deltaSeconds) + "s"
                + " n=\(playerCount)/snapshot=\(snapshotCount)"
                + " horizon=" + String(format: "%.4f", horizonSeconds) + "s"
                + " overruns=\(overrunCount)"
                + " overrunSec=" + String(format: "%.4f", overrunSeconds)
                + " clampDowns=\(clampDownCount)"
                + " restarts=\(restartsBefore)->\(restartsAfter)"
                + " gap=" + String(format: "%.1f", gapSeconds * 1000) + "ms"
        }
    }

    /// 120 BPM (the `TransportState` default) → 2 beats per second. The literal
    /// `2.0` in every closed form below IS this number; it is spelled out
    /// rather than named so the arithmetic is readable inline.
    static var beatsPerSecond: Double { 2.0 }

    /// THE CONTINUITY EPSILON — in BEATS.
    ///
    /// DERIVED, NOT GUESSED. On the healthy path `after.host` is an INTEGER
    /// COPY of the instant `after.beats` was derived for, so the residue is the
    /// float error of one host-tick → seconds → beat round trip: the engine
    /// evaluates `tempoMap.beat(from: b0, elapsedSeconds: s)` where this file
    /// evaluates `b0 + 2.0 * s` on the same `s`, and at a constant 120 BPM map
    /// those are the same computation. It does NOT scale with the work, the
    /// project or the machine — load determines only WHICH PATH is taken, and
    /// the overrun counter reports that in band. So this is a float tolerance,
    /// not a guessed millisecond threshold: the m23-bu-1 rule satisfied by
    /// REMOVING the exposure rather than surviving it.
    ///
    /// MEASURED WORST, ~12 runs 2026-08-02 (filtered and full-suite):
    /// **2.220e-16 beats — ONE ULP — observed once; every other sample read
    /// exactly 0.000e+00.** The value is printed on every run; see the
    /// `[measured] m23-bs-2 L1 residue=` lines. ⚠️ An earlier draft of this
    /// comment claimed "exactly zero in EVERY sample" off the first 5 runs; a
    /// later run falsified it. Corrected rather than left standing, because in
    /// this tree a written measurement gets quoted forward.
    ///
    /// ⚠️ THE DESIGN'S TIGHTENING RULE IS DEGENERATE HERE AND MUST NOT BE
    /// APPLIED LITERALLY. §9.1/§13.7 say "tighten to measured-worst × 10,
    /// expect ~1e-6". The measured worst is 0, so × 10 prescribes **0** — an
    /// exact float-equality assertion. That is not a tolerance, and it would
    /// convert this leg's failure mode from "the engine is wrong" to "the
    /// fixture's tempo map changed shape": the residue is zero only because at
    /// a CONSTANT 120 BPM map the engine's
    /// `tempoMap.beat(from: b0, elapsedSeconds: s)` and this file's
    /// `b0 + 2.0 · s` round identically. A fixture starting at a non-zero beat
    /// or a map with segments would legitimately produce ULP error, and a zero
    /// epsilon would red a CORRECT engine — the worse failure direction for the
    /// one assertion that must never be loosened under pressure.
    ///
    /// 1e-12 IS DERIVED FROM THAT: the ULP of this arithmetic at the fixture's
    /// beat magnitudes is 2.2e-16 (L4 measured exactly one ULP once, in 1 of 5
    /// runs), so 1e-12 is ~4500 ULP of headroom — enough to stay valid if the
    /// roll or the start beat grows by three orders of magnitude, while
    /// remaining **2.6e11× below the entry-derivation mutant's 0.264 beats**.
    /// The margin this leg needs is against the DEFECT, and it has 11 orders of
    /// it.
    ///
    /// ⚠️ Anything above 1e-4 is a PRECISION PROBLEM TO UNDERSTAND, not a
    /// tolerance to widen. A guessed-loose epsilon on the one assertion
    /// carrying this item's regression guard is the same failure as a guessed
    /// timing ceiling, one layer in.
    static var continuityEpsilonBeats: Double { 1e-12 }

    /// L4's epsilon. §9.3 permits this to be LOOSER than L1's — the modular
    /// branch evaluates `(s − headSeconds) mod cycleSeconds` plus a `min`
    /// clamp, where this file reconstructs `headSeconds`/`cycleSeconds` from
    /// the loop bounds through a DIFFERENT expression than the engine's map
    /// integral (exact only for a constant map). MEASURED WORST over the same
    /// 5 runs: **2.220e-16 beats, one ULP**, in 1 of 5 samples; the other four
    /// were exactly zero. So the extra operations cost at most one ULP here and
    /// the same 1e-12 is kept rather than invented looser — it is already
    /// 3e12× below the linear-branch mutant's ~3 beats. Stated rather than
    /// picked, per §9.3.
    static var loopContinuityEpsilonBeats: Double { 1e-12 }

    /// The one-track held-note fixture, matching this suite's own.
    static func heldNoteTrack() -> Track {
        Track(name: "Keys", kind: .instrument,
              clips: [Clip(name: "midi", startBeat: 0, lengthBeats: 512, notes: [
                  MIDINote(pitch: 69, velocity: 100, startBeat: 0, lengthBeats: 512),
              ])],
              instrument: InstrumentDescriptor(kind: .testTone))
    }

    /// δ — how far `outputNode.lastRenderTime.hostTime` LEADS
    /// `mach_absolute_time()`, measured directly on a running throwaway engine.
    ///
    /// This is bs-1's ~14 ms residual, and §13.1 derives it as one mechanism
    /// rather than two competing hypotheses: a render callback is handed a
    /// PRESENTATION-domain timestamp, and it executes about one buffer plus the
    /// presentation latency before that instant. It is a property of the
    /// DEVICE, not of the recovery work, which is why bs-1 measured it
    /// invariant to project size and to whether the engine bounced.
    ///
    /// ⚠️ δ IS NOT ADDED TO THE RESUME BEAT and must never be. Both anchor
    /// instants are presentation-domain and mean the same thing — "the wall
    /// moment this beat is AUDIBLE" — so preserving the outgoing line preserves
    /// what is coming out of the speaker. Adding δ would push the AUDIO forward
    /// by ~14 ms to make a DISPLAY reading continuous: an audio discontinuity
    /// introduced to hide a display one, which is design §3.2's failure class.
    ///
    /// ⚠️ Only valid on a LIVE engine — after a stop the render clock reports
    /// the previous session (that is m23-bq's whole finding), so this uses a
    /// throwaway engine rather than a production seam whose validity would
    /// depend on the branch taken. Returns nil when no device is available.
    /// ⚠️ δ IS A SAWTOOTH, NOT A SCALAR — MEASURED 2026-08-02, and this is a
    /// refinement §13.1 does not state. `lastRenderTime.hostTime` is the
    /// presentation instant of the buffer currently being filled; it holds
    /// STILL between callbacks while `mach_absolute_time()` advances, so a
    /// single read lands at an arbitrary phase and δ ramps DOWN by one buffer
    /// period across each callback interval. Twenty-four settled samples on
    /// this machine: 0.0125–0.0222 s, a 0.0097 s span ≈ exactly one buffer
    /// (512/48 kHz = 0.01067 s); across runs the observed extremes are
    /// 0.0116–0.0222 s. So δ ranges over
    /// `[buffer + latency, 2·buffer + latency]`, i.e. the AUHAL presents one
    /// buffer further ahead than the plainest reading of §13.1's mechanism.
    ///
    /// THE MINIMUM IS THE STABLE ESTIMATOR and it is the one reported: it
    /// matches the `buffer + latency` cross-check to ≲1 ms (0.0125 vs 0.0119 on
    /// the 24-sample loop; 0.0116 vs 0.0119 on an earlier run), and β·min ≈
    /// 0.023–0.025 beats predicted the MEASURED in-run recovery delta of
    /// 0.026 beats. The median (~0.017) over-reads by ~40 % and would predict
    /// 0.034. So §13.1's mechanism holds in magnitude and its cross-check is
    /// the sounder of its two derivations — the opposite of the section's
    /// "direct read preferred, load-bearing" ranking.
    ///
    /// ⚠️ THE MINIMUM IS ONLY STABLE IF THE SAMPLES COVER THE TOOTH — see the
    /// spacing comment in the loop below. A minimum taken from samples that all
    /// land at one phase is a floor estimate of nothing.
    ///
    /// ⚠️ NOT MEASURED ON THE FIRST CALLBACK either: taken there it reads
    /// ~0.022 s (the top of the sawtooth plus a start-up transient), which
    /// would falsify the mechanism for the wrong reason.
    static func measureRenderClockLeadSeconds() -> Double? {
        let probe = AVAudioEngine()
        _ = probe.mainMixerNode          // forces the mixer→output connection
        probe.prepare()
        do { try probe.start() } catch { return nil }
        defer { probe.stop() }

        // Wait for the first callback, then let the pipeline settle.
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline, probe.outputNode.lastRenderTime == nil { usleep(5_000) }
        usleep(200_000)

        // ⚠️ THE SPACING IS THE WHOLE ESTIMATOR — DO NOT "TIDY" IT TO ONE BUFFER
        // PERIOD. The first version of this loop took 9 samples at 11 ms, chosen
        // as "~1 buffer at 512/48k so successive reads differ". That is exactly
        // WRONG for a sawtooth of period 10.67 ms: sampling at the period lands
        // every read at nearly the SAME phase, drifting only 0.3 ms per step, so
        // the 9 samples covered a 7.1 ms arc of a 10.7 ms tooth and the minimum
        // over-read the true floor by 2.9 ms (measured: min 0.0148 against a
        // 0.0119 cross-check — it looked like a mechanism disagreement and was
        // an aliasing artefact of my own sampler). 3 ms is deliberately
        // incommensurate with the buffer period, and 24 samples span ~7 teeth.
        var samples: [Double] = []
        for _ in 0..<24 {
            guard let render = probe.outputNode.lastRenderTime, render.isHostTimeValid else {
                break
            }
            let now = mach_absolute_time()
            samples.append(render.hostTime >= now
                           ? AVAudioTime.seconds(forHostTime: render.hostTime - now)
                           : -AVAudioTime.seconds(forHostTime: now - render.hostTime))
            usleep(3_000)
        }
        guard !samples.isEmpty else { return nil }
        // The floor of the sawtooth — see this function's doc comment.
        let delta = samples.min() ?? 0

        // CROSS-CHECK, PRINTED AND NEVER ASSERTED (§13.1). δ should equal one
        // buffer plus the presentation latency, because a render callback is
        // handed a PRESENTATION-domain timestamp and executes about that far
        // ahead of it. The two derivations are wanted TOGETHER precisely
        // because their agreement is a falsifiable prediction rather than an
        // assumption — a persistent disagreement means §13.1's mechanism is
        // wrong and the section needs re-reading. ⚠️ The buffer size is read
        // off THIS ENGINE's output device, not `HardwareDevices.defaultDeviceID`
        // — m20-j gave the app an app-local output pin, so the default device
        // and an engine's device can differ (bs-1's helper takes the default).
        let rate = probe.outputNode.outputFormat(forBus: 0).sampleRate
        let latency = probe.outputNode.presentationLatency
        var frames: UInt32 = 0
        if let audioUnit = probe.outputNode.audioUnit {
            var deviceID = AudioDeviceID(0)
            var idSize = UInt32(MemoryLayout<AudioDeviceID>.size)
            if AudioUnitGetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global, 0, &deviceID, &idSize) == noErr {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyBufferFrameSize,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: kAudioObjectPropertyElementMain
                )
                var size = UInt32(MemoryLayout<UInt32>.size)
                _ = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &frames)
            }
        }
        let predicted = rate > 0 ? Double(frames) / rate + latency : 0
        print("[measured] m23-bs-2 delta(render-clock lead, sawtooth FLOOR)="
              + String(format: "%.4f", delta)
              + "s  crossCheck(buffer+latency)=" + String(format: "%.4f", predicted) + "s"
              + " diff=" + String(format: "%.4f", delta - predicted) + "s"
              + " | bufferFrames=\(frames) rate=" + String(format: "%.0f", rate)
              + " presentationLatency=" + String(format: "%.4f", latency) + "s"
              + " samples=\(samples.map { String(format: "%.4f", $0) })")
        return delta
    }

    /// Rolls, bounces through `watchdogRestart()`, and reads both anchor lines.
    /// nil ⇒ no output device (the suite's `liveSmoke` idiom, and it means THAT
    /// AND NOTHING ELSE).
    ///
    /// ⚠️ `watchdogRestart` is used rather than `recoverEngine` alone so the
    /// `if !engine.isRunning` branch really runs; `restartsBefore/After` is the
    /// m23-bt discriminator, because a green read-back against a recovery that
    /// early-returned proves nothing at all.
    static func bounceAndReadAnchors(tracks: [Track], transport: TransportState,
                                     rollMs: Int) async throws -> Continuity? {
        let engine = AudioEngine()
        do {
            try engine.prepare()
        } catch {
            return nil   // headless machine, no output device — labeled gap
        }
        defer { engine.shutdown() }

        engine.tracksDidChange(tracks)
        engine.startPlayback(transport)
        try await Task.sleep(for: .milliseconds(rollMs))

        guard let before = engine.anchorLineForTesting else {
            Issue.record("no anchor after startPlayback — the transport never started")
            return nil
        }
        let snapshot = engine.graph.startablePlayerCount
        let restartsBefore = engine.recoveryRestartCountForTesting

        let gapStart = mach_absolute_time()
        try engine.watchdogRestart()

        guard let after = engine.anchorLineForTesting else {
            let threw: String = "no anchor after watchdogRestart — recovery THREW; nothing "
                + "below this can be read. Check stderr for the recovery failure."
            Issue.record("\(threw)")
            return nil
        }
        let gapSeconds = after.anchorHostTime >= gapStart
            ? AVAudioTime.seconds(forHostTime: after.anchorHostTime - gapStart)
            : 0
        engine.stopPlayback()

        return Continuity(
            before: AnchorLine(beats: before.startBeats, host: before.anchorHostTime),
            after: AnchorLine(beats: after.startBeats, host: after.anchorHostTime),
            restartsBefore: restartsBefore,
            restartsAfter: engine.recoveryRestartCountForTesting,
            overrunCount: engine.continuationOverrunCountForTesting,
            overrunSeconds: engine.lastContinuationOverrunSecondsForTesting,
            clampDownCount: engine.continuationClampDownCountForTesting,
            horizonSeconds: engine.lastContinuationHorizonSecondsForTesting,
            playerCount: engine.lastContinuationPlayerCountForTesting,
            snapshotCount: snapshot,
            gapSeconds: gapSeconds
        )
    }

    /// The m23-bt discriminator, applied identically by every leg below.
    static func requireRealRestart(_ reading: Continuity) -> Bool {
        let why: String = "recovery did NOT take its restart branch across watchdogRestart "
            + "(restarts \(reading.restartsBefore) -> \(reading.restartsAfter)). Every "
            + "assertion in this file would then be reading an anchor pair that no recovery "
            + "produced — green for the wrong reason. " + reading.rendered
        #expect(reading.restartsAfter == reading.restartsBefore + 1, "\(why)")
        return reading.restartsAfter == reading.restartsBefore + 1
    }

    // MARK: - L1 + L2: the anchor line is continuous across a recovery

    /// L1 (the regression guard, SKIPPABLE on an engine-reported overrun) and
    /// L2 (consistency, NEVER skipped) ride one live session.
    @Test("live: the recovery anchor lands on the OUTGOING anchor's line (m23-bs-2)")
    func recoveryPreservesTheAnchorLine() async throws {
        // δ — printed once per suite run, never asserted on. It is what makes
        // `RecoveryPlayheadTests`' 0.25 ceiling and 0.10 delta re-derivable on
        // hardware with a different output buffer size, which §13.10 names as
        // the design's least-tested assumption. Nothing in THIS file depends on
        // it: L1/L2/L4 compare two anchor pairs, and δ cancels.
        if let delta = Self.measureRenderClockLeadSeconds() {
            // β·δ, NOT "2·δ": the factor is beats-per-second (2.0 at the
            // fixture's 120 BPM), which §13.1's "2·δ" silently conflates with a
            // factor of two. At 60 BPM the same δ costs half the beats.
            print("[measured] m23-bs-2 expected post-fix lag = control + beta*delta = control + "
                  + String(format: "%.3f", Self.beatsPerSecond * delta)
                  + " beats (beta=" + String(format: "%.1f", Self.beatsPerSecond)
                  + " beats/s; delta is the sawtooth FLOOR, so this is the band's LOW end)")
        } else {
            print("[measured] m23-bs-2 delta(render-clock lead): UNMEASURED — no output device "
                  + "or no render callback within 1 s")
        }

        var transport = TransportState()
        transport.isPlaying = true
        guard let reading = try await Self.bounceAndReadAnchors(
            tracks: [Self.heldNoteTrack()], transport: transport, rollMs: 500) else {
            print("[measured] m23-bs-2: NO OUTPUT DEVICE — anchor-continuity leg skipped")
            return
        }
        print("[measured] m23-bs-2 L1/L2 \(reading.rendered)")
        guard Self.requireRealRestart(reading) else { return }

        // The closed form, computed HERE — never by the engine (see the header).
        let expected = reading.before.beats + Self.beatsPerSecond * reading.deltaSeconds
        let residue = abs(reading.after.beats - expected)
        print("[measured] m23-bs-2 L1 residue=" + String(format: "%.3e", residue)
              + " beats (epsilon " + String(format: "%.3e", Self.continuityEpsilonBeats)
              + "; measured worst 2.220e-16 = 1 ULP, once in ~12 runs — see the constant's "
              + "doc comment for why the epsilon is NOT that number)")

        // A clamp-DOWN is a caller bug, never load, and it invalidates the
        // healthy-path reasoning for both assertions below.
        let bug: String = "the continuation anchor was clamped DOWN — a caller computed its "
            + "horizon somewhere other than StartAnchorBudget. " + reading.rendered
        #expect(reading.clampDownCount == 0, "\(bug)")

        // L2 — CONSISTENCY, NEVER SKIPPED. It relates two INDEPENDENTLY
        // EXPORTED quantities (the anchor pair and the reported overrun), so it
        // holds regardless of load or which path ran, and it catches a wrong
        // derivation that is not reported as an overrun: a wrong tempo map, the
        // wrong loop branch, a sign error.
        let overrunBeats = Self.beatsPerSecond * reading.overrunSeconds
        let inconsistent: String = "L2: the recovery anchor is off the outgoing line by more "
            + "than the engine's OWN reported overrun. residue="
            + String(format: "%.3e", residue) + " reportedOverrunBeats="
            + String(format: "%.3e", overrunBeats) + ". This is a WRONG DERIVATION, not "
            + "load — the two quantities are exported independently, so no amount of "
            + "starvation can produce this. Suspect the tempo map, the loop branch or a "
            + "sign. " + reading.rendered
        #expect(residue <= overrunBeats + Self.continuityEpsilonBeats, "\(inconsistent)")

        // L1 — THE REGRESSION GUARD. Skipped LOUDLY on an engine-reported
        // overrun: a starved window is a machine fact, and failing on it
        // produces a red that blames the harness, which is what trains the next
        // person to delete the guard. L2 above and L3 below are what stop this
        // skip from becoming a coverage hole.
        if reading.overrunCount > 0 {
            print("[measured] m23-bs-2 L1 SKIPPED — budget overrun x\(reading.overrunCount), "
                  + "worst " + String(format: "%.1f", reading.overrunSeconds * 1000) + " ms. "
                  + "L2 and L3 still ran.")
            return
        }
        let why: String = "m23-bs REGRESSION: the recovery anchor is NOT on the outgoing "
            + "anchor's line, and the engine reported NO overrun — so this is the derivation "
            + "itself, not the budget. `startBeats` must be the beat that occurs at "
            + "`anchorHostTime`, for the clip schedule, the automation origin, the metronome, "
            + "the reference track and the playhead simultaneously; a start that derives its "
            + "beat at one instant and anchors at another republishes a line the music is not "
            + "on, PERMANENTLY. Check that recoverEngine still derives its resume beat AFTER "
            + "segment A and passes `.atHostTime` with the SAME instant. residue="
            + String(format: "%.3e", residue) + " " + reading.rendered
        #expect(residue <= Self.continuityEpsilonBeats, "\(why)")
    }

    // MARK: - L3: the forecast reads its count at the RIGHT MOMENT

    /// ⚠️ THE DISCRIMINATOR IS THE COUNT, NOT THE HORIZON. If the count read
    /// moves below `graph.stopAllPlayers()` it reads 0 — `noteStopped()` zeroes
    /// the enqueue ledger — the horizon collapses to floor + allowance, and a
    /// large project under-predicts its anchor by up to 0.44 s. That is silent
    /// and PROJECT-SIZE-DEPENDENT. Asserting the reported COUNT against this
    /// test's own snapshot catches it at n ≥ 1, on ONE audio clip, with no
    /// floor clamp masking anything and nothing to compute.
    ///
    /// An earlier draft keyed this leg on the HORIZON and therefore needed a
    /// ≥ 6-audio-clip fixture (below 6 the lead is pinned at the floor, so a
    /// horizon assertion cannot tell the mutant from a correct implementation)
    /// — a whole extra live session the contention budget had just committed
    /// not to add. THE DECOMPOSITION, written down so the big fixture is not
    /// reinstated: L0 (`StartAnchorBudgetTests`, headless) owns THE FORMULA;
    /// this leg owns THE READ SITE.
    ///
    /// ⚠️ ANTI-VACUITY: `snapshotCount >= 1`, asserted with its reason. An
    /// ALL-MIDI fixture reads 0 on both sides and proves nothing, because
    /// `startablePlayerCount` walks `trackNodes` (AUDIO clip nodes) while
    /// instrument tracks live in `instrumentNodes`. The audio clip therefore
    /// sits in the FUTURE (bs-1's beats 4…28 convention) — `scheduleAll` drops
    /// a clip whose source is exhausted at the resume beat.
    ///
    /// THE ASSUMPTION THIS RESTS ON, stated so a future change fails loudly
    /// rather than blindly: the snapshot is comparable to the engine's entry
    /// read only because the enqueue ledger survives `engine.stop()`.
    /// `noteStopped()` is called from `stopAllPlayers()` alone (grep-verified,
    /// `PlaybackGraph.swift`), and `watchdogRestart` reaches
    /// `graph.stopAllPlayers()` only AFTER the count read. If that changes,
    /// this leg goes spuriously RED rather than silently blind — the right
    /// failure direction, but only if someone knows why.
    @Test("live: the continuation horizon is forecast from the count read BEFORE stopAllPlayers")
    func forecastReadsTheLiveCount() async throws {
        let fixtures = try TestSignals.fixtures()
        let tracks = [
            Self.heldNoteTrack(),
            Track(name: "Audio", kind: .audio,
                  clips: [Clip(name: "future", startBeat: 4, lengthBeats: 4,
                               audioFileURL: fixtures.cos1k48)]),
        ]
        var transport = TransportState()
        transport.isPlaying = true
        guard let reading = try await Self.bounceAndReadAnchors(
            tracks: tracks, transport: transport, rollMs: 200) else {
            print("[measured] m23-bs-2: NO OUTPUT DEVICE — forecast-source leg skipped")
            return
        }
        print("[measured] m23-bs-2 L3 \(reading.rendered)")
        guard Self.requireRealRestart(reading) else { return }

        let hollow: String = "ANTI-VACUITY FAILURE: the fixture had ZERO startable players, so "
            + "the count reads 0 on BOTH sides of the landmine and this leg proves nothing. "
            + "`startablePlayerCount` walks trackNodes (AUDIO clip nodes); instrument tracks "
            + "live in instrumentNodes and contribute none. Check that the audio clip still "
            + "resolves its fixture file and still sits in the FUTURE relative to the resume "
            + "beat — scheduleAll drops a clip whose source is exhausted there. "
            + reading.rendered
        #expect(reading.snapshotCount >= 1, "\(hollow)")

        let landmine: String = "m23-bs-2 LANDMINE: recovery forecast its horizon from "
            + "\(reading.playerCount) startable players where this test's own snapshot, taken "
            + "immediately before the bounce, says \(reading.snapshotCount). A reported 0 means "
            + "the count read has moved BELOW `graph.stopAllPlayers()`, whose `noteStopped()` "
            + "zeroes the enqueue ledger — the horizon then collapses to the floor and a large "
            + "project under-predicts its anchor by up to 0.44 s, SILENTLY and in proportion "
            + "to project size. Move the read back above the stop. " + reading.rendered
        #expect(reading.playerCount == reading.snapshotCount, "\(landmine)")

        // The horizon identity — an EXACT read-back against the one home,
        // strictly stronger than a [floor, cap] range check and it subsumes the
        // anti-degenerate assertion (a horizon ≡ 0 fails it). ⚠️ It is NOT
        // required to be non-vacuous at low n: below 6 players the lead is
        // pinned at the floor, so this cannot discriminate the count-source
        // mutant. L0 carries the formula's burden; the assertion above carries
        // this leg's.
        let expectedHorizon = StartAnchorBudget.continuationHorizonSeconds(
            forStartablePlayerCount: reading.snapshotCount)
        let drifted: String = "the horizon recovery used (\(reading.horizonSeconds)) is not "
            + "StartAnchorBudget.continuationHorizonSeconds(\(reading.snapshotCount)) = "
            + "\(expectedHorizon). Either a second copy of the budget formula has appeared, or "
            + "the horizon is no longer computed from the count this leg pins. "
            + reading.rendered
        #expect(reading.horizonSeconds == expectedHorizon, "\(drifted)")
        #expect(reading.clampDownCount == 0, "\(drifted)")
    }

    // MARK: - L4: the loop wrap survives the recovery

    /// ⚠️ THE ONLY AUTOMATED CHECK FOR THE §5.1 MISTAKE — do not drop it.
    /// `startPlayers` sets `loopContext = nil` on the way in and rebuilds it, so
    /// an implementation that moved the resume derivation INSIDE `startPlayers`
    /// (the single most likely way to get this item wrong, because it looks
    /// tidier) silently takes the LINEAR branch of `beat(forElapsedSeconds:)`
    /// and loses the modular wrap. That implementation reds HERE while the
    /// loop-off leg above stays perfectly green.
    ///
    /// A later derivation crossing a loop seam is CORRECT, not a hazard: wall
    /// time kept moving, the loop kept cycling, and the listener's position is
    /// inside the next cycle.
    ///
    /// The expectation is computed test-side from the loop bounds, exactly as
    /// the engine's modular branch does: `within = (s − head) mod cycle`,
    /// `expected = loopStart + 2·within`.
    @Test("live: a recovery under an active loop resumes MODULARLY, not linearly")
    func recoveryUnderALoopWrapsModularly() async throws {
        let loopStartBeat = 0.0
        let loopEndBeat = 2.0            // 1.0 s per cycle at 120 BPM
        var transport = TransportState()
        transport.isPlaying = true
        transport.isLoopEnabled = true
        transport.loopStartBeat = loopStartBeat
        transport.loopEndBeat = loopEndBeat

        // Roll well past the first wrap so the recovery lands inside a later
        // cycle rather than in the head pass.
        guard let reading = try await Self.bounceAndReadAnchors(
            tracks: [Self.heldNoteTrack()], transport: transport, rollMs: 1_500) else {
            print("[measured] m23-bs-2: NO OUTPUT DEVICE — loop-wrap leg skipped")
            return
        }
        print("[measured] m23-bs-2 L4 \(reading.rendered)")
        guard Self.requireRealRestart(reading) else { return }

        // The engine's LoopContext for the outgoing roll: the head pass runs
        // from the start beat to the loop end, then whole cycles.
        let headSeconds = (loopEndBeat - reading.before.beats) / Self.beatsPerSecond
        let cycleSeconds = (loopEndBeat - loopStartBeat) / Self.beatsPerSecond
        let elapsed = reading.deltaSeconds

        let short: String = "the roll did not reach the first wrap (elapsed "
            + String(format: "%.3f", elapsed) + "s <= head "
            + String(format: "%.3f", headSeconds) + "s), so this leg exercised the LINEAR "
            + "branch and cannot tell a modular derivation from a linear one. Lengthen "
            + "rollMs. " + reading.rendered
        #expect(elapsed > headSeconds, "\(short)")
        guard elapsed > headSeconds else { return }

        let within = (elapsed - headSeconds).truncatingRemainder(dividingBy: cycleSeconds)
        let expected = loopStartBeat + Self.beatsPerSecond * within
        let residue = abs(reading.after.beats - expected)
        print("[measured] m23-bs-2 L4 within=" + String(format: "%.4f", within) + "s"
              + " expected=" + String(format: "%.6f", expected)
              + " residue=" + String(format: "%.3e", residue) + " beats")

        // ⚠️ THE SEAM IS THE SNAP'S TERRITORY, NOT THIS LEG'S. When `within`
        // lands within float noise of a cycle boundary, `resumeBeat`'s
        // `>= loopEndBeat` guard (§5.2) fires and returns `loopStartBeat` —
        // correct, and deliberately NOT what the closed form above predicts.
        // Measure-zero, but the bounce instant is not controllable under load,
        // so report rather than flake.
        let seamSlack = 1e-6
        if within < seamSlack || cycleSeconds - within < seamSlack {
            print("[measured] m23-bs-2 L4 SKIPPED — the bounce landed on the loop seam "
                  + "(within=" + String(format: "%.3e", within) + "s), which is the §5.2 "
                  + "snap's territory rather than the modular branch's.")
            return
        }

        if reading.overrunCount > 0 {
            print("[measured] m23-bs-2 L4 SKIPPED — budget overrun x\(reading.overrunCount)")
            return
        }

        let linear = reading.before.beats + Self.beatsPerSecond * elapsed
        let why: String = "m23-bs-2 §5.1 REGRESSION: a recovery under an active loop did NOT "
            + "wrap modularly. Expected " + String(format: "%.6f", expected) + " (loop start + "
            + "the position inside the current cycle); got "
            + String(format: "%.6f", reading.after.beats) + ". The LINEAR value would be "
            + String(format: "%.6f", linear) + " — if that is what you see, the resume "
            + "derivation has moved INSIDE `startPlayers`, which clears `loopContext` on the "
            + "way in. It must stay in `recoverEngine` at the call site. " + reading.rendered
        #expect(residue <= Self.loopContinuityEpsilonBeats, "\(why)")
    }
}
