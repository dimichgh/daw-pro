import AVFAudio
import CoreAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m23-bs-1 — THE GATE MEASUREMENT: where does recovery's BACKWARD transport
// step actually go, and does it scale with the project?
//
// INSTRUMENTATION AND MEASUREMENT ONLY. Nothing here changes engine behaviour
// and nothing here is a regression guard for a fix — m23-bs-2 is the fix. This
// file exists to produce ONE decision: whether bs-2's anchor budget can be a
// CONSTANT or has to be measured adaptively at runtime.
//
// THE QUANTITY. `recoverEngine` derives its resume beat from the host clock at
// ENTRY and only anchors playback once all of its work is finished, so the
// transport resumes behind the music by
//
//     backward step  =  segment A  +  segment B  +  lead
//
// (`AudioEngine.swift`, the "m23-bs-1" seam block).
//
// ⚠️ THE CROSS-CHECK IS THE STEP, NOT THE LAG — and getting this wrong makes
// the seams look broken when they are not. `RecoveryPlayheadTests`' absolute
// `maxLagBeats` is measured against a `t0` taken after `startPlayback` returns,
// so it already carries the FIRST start's lead (~0.12 beats on the one-clip
// fixture) plus whatever the post-anchor serial start loop costs — on a project
// with many audio players `startPlayback` can even return AFTER its own anchor,
// which drives the absolute lag to 0.000 and makes it meaningless as a
// reconciliation target. This file therefore reports the ADDED lag: the median
// settled lag in a window just before the bounce, subtracted from the median in
// a window well after it. `t0` cancels in that difference, so
//
//     measuredStep (s)  =  (lagAfter − lagBefore) / 2       at 120 BPM
//     predictedStep (s) =  A + B + lead
//     residual          =  measuredStep − predictedStep
//
// and the control leg (`bounce=none`) is the metric's own positive control: it
// must read a step of ≈ 0.
//
// A non-zero residual is a REAL FINDING, not slop — it is time the transport
// loses that none of the three seams explains, and m23-bs-2's budget has to
// account for it. It is reported, never smoothed away.
//
// ⚠️ THE ONE-CLIP FIXTURE IS STRUCTURALLY BLIND TO THE HEADLINE QUESTION, which
// is why this file carries a SECOND project shape. Segment B is per-clip work
// (`scheduleAll` walks every clip; `prepareAllPlayers` pre-decodes 8192 frames
// for every player with a pending schedule) and the lead is per-PLAYER work
// (`0.02 + n * 0.008`, sized for the serial `play(at:)` loop). `RecoveryPlayhead-
// Tests` uses ONE instrument track with ONE clip, where both terms are at their
// floor: it cannot see either slope.
//
// ⚠️ AND AN ALL-MIDI "BIG" PROJECT WOULD BE JUST AS BLIND — the trap this
// fixture is built to avoid. `startablePlayerCount` and `prepareAllPlayers`
// both iterate `trackNodes` (AUDIO clip nodes); instrument tracks live in
// `instrumentNodes` and contribute neither a startable player nor a decode.
// A 32-clip MIDI-only project therefore leaves the lead pinned at the 0.06 s
// floor and `prepareAllPlayers` a no-op, and would report a comfortingly small
// B that means nothing. The realistic shape is HALF AUDIO by construction, and
// the `lead > 0.0601` assertion in `realisticProjectSplit` is its anti-vacuity
// check: if the lead reads the 0.06 s floor then no audio players were pending
// and the leg proved nothing.
//
// ⚠️ THE AUDIO CLIPS SIT IN THE FUTURE (beats 4…28), deliberately.
// `scheduleAll` drops a clip whose source is already exhausted at the resume
// beat (`guard sourceStart < fileLength`, `guard frameCount > 0`), so clips laid
// across the first few beats would have stopped existing by the ~beat-1.6
// resume and the project would silently shrink to nothing under measurement.
//
// ⚠️ NO TIMING ASSERTION — BY DESIGN (m23-bu-1's rule, docs/ARCHITECTURE.md).
// The playhead-lag cross-check is PRINTED and never `#expect`ed. Its left-hand
// side is a `Date()` taken inside a main-actor callback, so full-suite
// starvation inflates it without bound (m23-bu-1 measured main-actor scheduling
// gaps of 1.8–4.2 s), and a bound generous enough to survive that would assert
// nothing. Everything this file DOES assert is a property witness or a
// monotone counter: the seams fired, the counters moved the way the branch
// says they must, and the realistic project really did carry audio players.
// The numbers are the deliverable; the assertions only stop the fixture from
// going quietly hollow.
//
// ── WHAT IT MEASURED (2026-08-02, 18-core machine, 48 kHz / 512-frame device) ─
// 5 filtered runs and 3 inside a full `./scripts/test.sh` (4499 tests / 464
// suites). Recorded here so a later reader does not have to re-run to know the
// shape of the answer; the numbers are one machine's, the SHAPE is what travels.
// ⚠️ EVERY RANGE BELOW IS THE FULL OBSERVED SPREAD, NOT A TYPICAL VALUE — an
// earlier pass of this same file reported a tidy "0.7–1.8 ms" for B off three
// runs, and the next five runs put a 10.3 ms sample in the middle of it. These
// are per-run SINGLE SAMPLES (one recovery event per leg per run), so the
// spread is the honest statistic and the max is not an outlier to discard.
//
//   SEGMENT B IS SMALL AND DOES NOT SCALE WITH THE PROJECT — but it is NOISY.
//   Filtered, on the recovery legs: 0.6–10.3 ms (median 1.4 over 20 samples).
//   Under full suite: 0.4–20.2 ms (median 0.7 over 12). The 32-CLIP PROJECT
//   READS *LOWER* THAN
//   THE 1-CLIP PROJECT (0.6–1.9 vs 0.7–10.3 filtered), so the term is not
//   per-clip work at these sizes at all; B is a synchronous span, so its tail
//   is OS preemption of the main thread, not scheduling cost. Either way it is
//   ~1 % of the backward step, and the design's premise that "the majority of
//   the defect is the schedule pass inside startPlayers" does not survive.
//
//   THE LEAD IS THE DOMINANT TERM, AND IT IS THE ONE THAT SCALES: 0.060 s at
//   one clip, 0.148 s at 16 pending audio players (12 of the ~200 ms total
//   step, i.e. three quarters of it). So the design's CONCLUSION was right for
//   the wrong reason — the growing term really is inside `startPlayers` and
//   really is unreachable by re-deriving the beat before the call, but it is
//   the anchor LEAD, not the schedule pass.
//
//   …AND THE LEAD IS STRUCTURALLY AWKWARD FOR bs-2, which is a finding in its
//   own right. It is computed from `graph.startablePlayerCount`, which is only
//   correct AFTER `scheduleAll` — i.e. deep inside `startPlayers`, downstream
//   of the call site where a "re-derive the beat first" fix would live (and
//   `startPlayers` clears `loopContext` on the way in, so the derivation cannot
//   simply move inward either). A caller that wanted to predict the anchor
//   instant would have to predict the pending-player count too, or the anchor
//   contract has to carry the lead back out. bs-2 has to solve that; it is not
//   an implementation detail.
//
//   SEGMENT A IS SECOND, AND IS TWO DIFFERENT THINGS.
//
//     • The NON-BOUNCE part (`stopAllPlayers` + `applyParameters` + the
//       reference-monitor re-land) is the `.recoverOnly` reading, and it
//       CLEANLY SCALES WITH TRACK COUNT: 0.2–0.3 ms at 1 track, 5.3–16.6 ms at
//       8 tracks, in both regimes.
//     • The BOUNCE part (`engine.prepare()` + `engine.start()`) is the
//       `.watchdog` minus `.recoverOnly` delta, and IT SPANS 0.9–48 ms —
//       ~47 ms on the trivial graph FILTERED but ~0.9 ms on the same graph
//       under full suite, versus ~28–41 ms on the realistic graph in BOTH
//       regimes. A "warm HAL" story is contradicted by the second pair (the
//       realistic shape does not drop under the same load that flattens the
//       trivial one). The data fits TWO overlapping mechanisms — a graph-size
//       term and an environment-dependent device-start term — and THESE SEAMS
//       CANNOT SEPARATE THEM. Stated as a range, because a 50× range on a term
//       m23-bs-2 must budget for is worth more honest than tidy.
//
//   THERE IS A ~14 ms RESIDUAL THE THREE SEAMS DO NOT EXPLAIN, and it is
//   REMARKABLY CONSTANT: 12.0–17.4 ms over 20 filtered recovery samples —
//   the same whether the project has 1 clip or 32, and the same whether the
//   engine bounced or not. TWO HYPOTHESES FIT, WITH OPPOSITE CONSEQUENCES:
//
//     (a) a fixed CLOCK-BASIS offset — recovery derives its resume beat from
//         `mach_absolute_time()` while the playhead it replaces was read off
//         the RENDER clock (`elapsedSeconds` takes the sample-time branch
//         whenever `hasSampleAnchor`), and `renderClockTrusted: false` then
//         switches the new anchor to the host clock. A constant: subtractable.
//
//     (b) the OUTPUT BUFFER — this machine reports bufferFrames=512 at 48 kHz
//         = 10.7 ms, plus presentationLatency 1.3 ms = 12.0 ms, which is the
//         residual band's floor to three decimals. If that is the mechanism
//         the term is NOT a constant: a user at 2048 frames would see ~44 ms,
//         and a budget keyed to 13 ms would be wrong by 30 ms.
//
//   ⚠️ NO SECOND BUFFER SIZE EXISTS READ-ONLY ON THIS MACHINE, so the match in
//   (b) is a coincidence this file CANNOT rule out. Measured 2026-08-02 by a
//   read-only `kAudioDevicePropertyBufferFrameSize` sweep of every output
//   device present: BlackHole 2ch, MacBook Pro Speakers and ZoomAudioDevice ALL
//   report 512 frames @ 48 kHz. (Their allowed RANGE is [15…4096] — so a second
//   point is reachable, but only by WRITING the buffer size on the user's audio
//   hardware, which is out of scope here and would move the live app.)
//   m23-bs-2 MUST NOT INHERIT "13 ms" AS A CONSTANT: either measure at a second
//   buffer size, or derive the term from the device's own `presentationLatency`
//   + buffer duration (both printed by `deviceContext()` on every leg,
//   precisely so this stays checkable). Sample RATE is a weak discriminator —
//   512 frames at 44.1 kHz is 11.6 ms vs 10.7 ms, inside the run-to-run spread.
//
//   ⚠️ `deviceContext()` ITSELF TOUCHES THE DEVICE — it instantiates a throwaway
//   `AVAudioEngine` once per sweep, and device warmth is one of the two
//   candidate mechanisms behind segment A's range above. It fires before the
//   `.none` leg (not immediately before `.watchdog`), and A's filtered values
//   are unchanged from the runs taken before it was added, so the perturbation
//   looks negligible — but bs-2 should know it is there before re-reading A.
//
//   ⚠️ THE FULL-SUITE REGIME BARELY MEASURES THE *STEP* AT ALL, and that is a
//   finding about the regime, not about recovery. The playhead publishes 20–23
//   samples per leg when filtered and 0–4 under full suite, so 5 of the 18
//   full-suite legs printed `⚠️STARVED(step-unreadable)` and most of the rest
//   computed their medians from ONE sample. The SEAM numbers (A, B, lead) are
//   unaffected — they are host-clock deltas inside the engine, not callback
//   observations — but any full-suite `measuredStep`/`residual` should be read
//   as indicative only. This is exactly the hole m23-bu-2 exists to close, and
//   it is marked rather than silently averaged.
//
//   ⚠️ THIS SUITE ADDS SIX LIVE PLAYBACK SESSIONS TO A FULL RUN, and one of six
//   full runs with it present failed a DIFFERENT live suite —
//   `GaplessLoopTransportTests` "live smoke: looped playback wraps the playhead
//   modularly" at `(wraps → 0) >= 1`, the same starvation signature (it counts
//   playhead pushes). That test's own m14-a close-out record already documents
//   this failure mode ("one run's live-smoke wrap-count undercounted under
//   parallel-suite starvation, 5 pushes/1.7 s vs 44 isolated — hardened to
//   wraps ≥ 1"), so it is pre-existing IN KIND. Whether this file raises its
//   rate is UNRESOLVED: 1 failure in 6 runs with the file present, 0 in 3 with
//   the file moved aside (4497/463, the pre-existing baseline) — which is far
//   too few samples to separate. Flagged so whoever keeps or drops this file
//   after m23-bs-2 decides knowingly; env-gating it (the
//   `DAWPRO_LIVE_OUTPUT_LOOPBACK` precedent) is the cheap remedy if it matters.
//
// Device-gated by the `RecoveryPlayheadTests` idiom: `prepare()` throwing means
// no output device (headless CI) and the leg is skipped with a printed label.
// ⚠️ nil means THAT AND NOTHING ELSE — an empty sample set is reported as
// `pushes=0 STARVED`, never folded into the no-device skip, because a skip
// prints a REASON and a wrong reason is worse than no reading.

// ═══ m23-bs-2: ENV-GATED OFF BY DEFAULT — set DAWPRO_M23BS_COSTSPLIT=1 ═══
//
//     DAWPRO_M23BS_COSTSPLIT=1 ./scripts/test.sh --filter RecoveryCostSplit
//
// CONTENTION, and it is a design constraint rather than housekeeping. Three
// live-playback suites contending for ONE physical output device is the
// condition behind the `GaplessLoopTransportTests` "(wraps → 0) >= 1" flake
// this file's own header flagged, and `.serialized` does not scope ACROSS
// suites (m23-bu-1). m23-bs-2 added three live sessions of its own, and its
// rule was that a default full run must not perform MORE live sessions than
// before. This file's six (2 shapes × 3 bounces) are the ones to give back.
//
// JUSTIFIED, NOT MERELY CONVENIENT — three reasons, and the third is the one
// that matters:
//   1. This file's own header says "nothing here is a regression guard for a
//      fix"; it is a GATE MEASUREMENT, and its gate has been passed.
//   2. Its findings are already written into that header, into
//      `docs/research/design-m23bs-recovery-anchor.md` §13, and into the
//      constants in `Sources/DAWEngine/StartAnchorBudget.swift`, each of which
//      carries the measurement that produced it.
//   3. After m23-bs-2, production forecasts its horizon from
//      `graph.startablePlayerCount` LIVE — it reads none of the `…ForTesting`
//      seams this file exercises — so nothing bs-2 depends on loses coverage.
//      The seams still fire; only the gating changed.
//
// KEEP THE FILE. It is how these numbers get re-measured on other hardware,
// which the design explicitly flags as unknown (a different output buffer size
// moves δ, and δ moves what `RecoveryPlayheadTests`' ceiling should be).
//
// ⚠️ THE SKIP PRINTS. m20-j's two unrun audible legs are the counter-example in
// this very tree: a silent skip looks EXACTLY like coverage.

@MainActor
@Suite("Recovery cost split — m23-bs-1 GATE measurement", .serialized)
struct RecoveryCostSplitTests {

    /// True unless `DAWPRO_M23BS_COSTSPLIT=1` is set — see the block above.
    private static var isGatedOff: Bool {
        ProcessInfo.processInfo.environment["DAWPRO_M23BS_COSTSPLIT"] != "1"
    }

    /// Prints the reason and returns true when the leg must not run. Never
    /// silent: a skip with no reason is worse than no reading.
    private static func announceSkipIfGated(_ leg: String) -> Bool {
        guard isGatedOff else { return false }
        print("[measured] m23-bs-1 \(leg): SKIPPED — measurement-only gate, off by default "
              + "since m23-bs-2 to keep the live-output-device contention budget down. "
              + "Re-run with DAWPRO_M23BS_COSTSPLIT=1 to re-measure on this hardware.")
        return true
    }

    // MARK: - Fixtures

    private enum Shape: String {
        /// `RecoveryPlayheadTests`' fixture, verbatim: one instrument track,
        /// one clip, one held note. Directly comparable to the baseline this
        /// item was handed (CONTROL 0.119–0.125 / RECOVER-ONLY 0.268–0.269 /
        /// RESTART 0.362–0.383 beats of lag).
        case oneClip
        /// ~30 clips over 8 tracks, HALF AUDIO — see the header. 16 audio clips
        /// (4 tracks × 4) + 16 MIDI clips (4 tracks × 4, 16 notes each).
        case realistic
    }

    private enum Bounce: String {
        /// No recovery at all: the reference the other two are read against.
        case none
        /// `recoverEngine()` alone — the configuration-change route. Its
        /// `if !engine.isRunning` guard means NO prepare()/start() here, so
        /// this leg isolates everything that is NOT the engine restart.
        case recoverOnly
        /// `watchdogRestart()`: `engine.stop()` then `recoverEngine()`, so the
        /// restart branch really runs. The difference from `.recoverOnly` is
        /// the cost of `prepare()` + `start()`.
        case watchdog
    }

    /// 120 BPM (the `TransportState` default) → 1 beat = 500 ms of music.
    private static let beatsPerMillisecond = 1.0 / 500.0
    /// Long enough for a live anchor with real elapsed time, short enough that
    /// six legs do not dominate the suite. This file does NOT need
    /// `RecoveryPlayheadTests`' 2000 ms — that length is sized to the m23-bq
    /// freeze signature (lag ≈ previous session length), which is fixed and is
    /// not what is being measured here.
    private static let rollMs = 800
    private static let observeMs = 900
    /// Half-width of the two settled windows either side of the mark. 400 ms is
    /// comfortably past the new anchor (A + B + lead is ≈ 0.2 s at worst here)
    /// and still leaves ~12 pushes a side at the 30 Hz playhead cadence.
    private static let settleMs = 400

    private static func heldNoteTrack() -> Track {
        Track(name: "Keys", kind: .instrument,
              clips: [Clip(name: "midi", startBeat: 0, lengthBeats: 512, notes: [
                  MIDINote(pitch: 69, velocity: 100, startBeat: 0, lengthBeats: 512),
              ])],
              instrument: InstrumentDescriptor(kind: .testTone))
    }

    /// 8 tracks / 32 clips: 4 audio tracks × 4 clips and 4 instrument tracks ×
    /// 4 clips of 16 notes. Clip onsets at beats 4/12/20/28, all in the future
    /// relative to the ~beat-1.6 resume (see the header's third ⚠️).
    private static func realisticTracks(_ fixtures: TestSignals.FixtureSet) -> [Track] {
        let sources = [fixtures.cos1k48, fixtures.cos1k48Quarter,
                       fixtures.sine440_44k1, fixtures.cos1k48]
        var tracks: [Track] = []
        for index in 0..<4 {
            let url = sources[index]
            let clips = (0..<4).map { slot in
                Clip(name: "audio-\(index)-\(slot)",
                     startBeat: Double(4 + slot * 8), lengthBeats: 4,
                     audioFileURL: url)
            }
            tracks.append(Track(name: "Audio \(index)", kind: .audio, clips: clips))
        }
        for index in 0..<4 {
            let clips = (0..<4).map { slot -> Clip in
                let base = Double(4 + slot * 8)
                let notes = (0..<16).map { step in
                    MIDINote(pitch: 48 + (index * 3 + step) % 24, velocity: 96,
                             startBeat: base + Double(step) * 0.25, lengthBeats: 0.25)
                }
                return Clip(name: "midi-\(index)-\(slot)", startBeat: base,
                            lengthBeats: 4, notes: notes)
            }
            tracks.append(Track(name: "Inst \(index)", kind: .instrument, clips: clips,
                                instrument: InstrumentDescriptor(kind: .testTone)))
        }
        return tracks
    }

    // MARK: - The reading

    private struct Split {
        let shape: Shape
        let bounce: Bounce
        /// nil for `.none` — recovery never ran, which is NOT the same fact as
        /// "recovery ran and cost nothing", and a bare 0.000 would conflate the
        /// two.
        let segmentA: Double?
        /// Segment B of the LAST start before the reading — the recovery's own
        /// start on the two recovery legs, `startPlayback`'s on `.none`.
        let segmentB: Double
        let lead: Double
        /// `startPlayback`'s reading, taken before the bounce: the only
        /// TRUSTED-branch (render-clock) sample, on the same project.
        let initialSegmentB: Double
        let initialLead: Double
        let restartsBefore: Int
        let restartsAfter: Int
        let pushesBeforeMark: Int
        let pushesAfterMark: Int
        /// Worst (wall-time-implied beat) − (pushed beat) after the mark — the
        /// SAME statistic `RecoveryPlayheadTests` asserts on, carried here only
        /// so the two files' numbers are comparable. Never asserted on.
        let maxLagBeats: Double
        /// MEDIAN lag over the settled window just BEFORE the mark, and over
        /// the settled window well after it. Both use the same `t0`, so the
        /// harness's own start offset cancels in their difference — which is
        /// why the step below is the trustworthy quantity and `maxLagBeats` is
        /// not (see the header).
        let settledLagBeforeBeats: Double?
        let settledLagAfterBeats: Double?

        /// `A + B + lead` — the backward step the transport SHOULD take if
        /// those three seams are the whole story. Exactly ZERO on the control
        /// leg: nothing re-anchored there, so no step is predicted and the
        /// seams' values (which belong to `startPlayback`, not to a bounce) are
        /// deliberately NOT summed into one.
        var predictedStepSeconds: Double {
            bounce == .none ? 0 : (segmentA ?? 0) + segmentB + lead
        }
        /// The backward step actually observed, in seconds: the lag the
        /// recovery ADDED, read within one run so `t0` cancels.
        var measuredStepSeconds: Double? {
            guard let before = settledLagBeforeBeats, let after = settledLagAfterBeats
            else { return nil }
            return (after - before) / 2   // 120 BPM: 1 beat = 0.5 s
        }
        /// Observed − predicted. A term the three seams do NOT explain.
        var residualSeconds: Double? {
            measuredStepSeconds.map { $0 - predictedStepSeconds }
        }
        /// Startable audio players, backed out of the post-cap lead. Only
        /// resolvable while the lead is above its 0.06 s floor.
        var playersFromLead: String {
            lead > 0.0601 ? "\(Int(((lead - 0.02) / 0.008).rounded()))" : "<=5"
        }

        private func beats(_ value: Double?) -> String {
            value.map { String(format: "%.3f", $0) } ?? "n/a"
        }
        private func seconds(_ value: Double?) -> String {
            value.map { String(format: "%.4f", $0) } ?? "n/a"
        }

        var rendered: String {
            let a = segmentA.map { String(format: "%.4f", $0) } ?? "n/a(no-recovery)"
            return "shape=\(shape.rawValue) bounce=\(bounce.rawValue)"
                + " A=\(a)s"
                + " B=" + String(format: "%.4f", segmentB) + "s"
                + " lead=" + String(format: "%.4f", lead) + "s"
                + " predictedStep=" + String(format: "%.4f", predictedStepSeconds) + "s"
                + " measuredStep=" + seconds(measuredStepSeconds) + "s"
                + " residual=" + seconds(residualSeconds) + "s"
                + " players=" + playersFromLead
                + " | lagBefore=" + beats(settledLagBeforeBeats) + "b"
                + " lagAfter=" + beats(settledLagAfterBeats) + "b"
                + " maxLagAfter=" + String(format: "%.3f", maxLagBeats) + "b"
                + " initialB=" + String(format: "%.4f", initialSegmentB) + "s"
                + " initialLead=" + String(format: "%.4f", initialLead) + "s"
                + " restarts=\(restartsBefore)->\(restartsAfter)"
                + " pushes=\(pushesBeforeMark)/\(pushesAfterMark)"
                // ⚠️ THE FLAG IS ON THE STEP, NOT ON THE PUSH COUNT. Under
                // full-suite starvation the AFTER window can be well populated
                // while the BEFORE window gets nothing (measured: `pushes=0/3`),
                // and the step needs BOTH. Flagging only an empty AFTER window
                // would have let a `measuredStep=n/a` slip out unmarked, which
                // is exactly the silent coverage hole m23-bu-2 is about.
                + (measuredStepSeconds == nil ? " ⚠️STARVED(step-unreadable)" : "")
                // The metric's own positive control: with no re-anchor the step
                // must read ~0. A drift here means the READING is off, and no
                // residual on the recovery legs of the same run can be trusted.
                + (bounce == .none && abs(measuredStepSeconds ?? 0) > 0.02
                   ? " ⚠️CONTROL-DRIFT(metric-unreliable-this-run)" : "")
        }
    }

    /// Median of a sample set; nil for an empty one. Median rather than mean or
    /// max because the left-hand side of every lag sample is a `Date()` taken
    /// inside a main-actor callback, which starvation delays upward only
    /// (m23-bu-1) — a max reads the worst delay, a median reads the transport.
    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func measure(_ shape: Shape, _ bounce: Bounce) async throws -> Split? {
        let engine = AudioEngine()
        do {
            try engine.prepare()
        } catch {
            return nil   // headless machine, no output device — labelled gap
        }
        defer { engine.shutdown() }

        switch shape {
        case .oneClip:
            engine.tracksDidChange([Self.heldNoteTrack()])
        case .realistic:
            engine.tracksDidChange(Self.realisticTracks(try TestSignals.fixtures()))
        }

        var samples: [(ms: Double, beat: Double)] = []
        var transport = TransportState()
        transport.isPlaying = true
        engine.startPlayback(transport)
        // Read BEFORE the bounce: the recovery's own start overwrites both.
        // This pair is the trusted (render-clock) branch's reading.
        let initialSegmentB = engine.startPlayersScheduleCostSecondsForTesting
        let initialLead = engine.lastStartLeadSecondsForTesting
        let restartsBefore = engine.recoveryRestartCountForTesting

        let t0 = Date()
        engine.playheadHandler = { beat in
            samples.append((Date().timeIntervalSince(t0) * 1000, beat))
        }
        try await Task.sleep(for: .milliseconds(Self.rollMs))

        let mark = Date().timeIntervalSince(t0) * 1000
        switch bounce {
        case .none: break
        case .recoverOnly: engine.recoverEngine()
        case .watchdog: try engine.watchdogRestart()
        }
        // Immediately, before anything else can start players again.
        let segmentA: Double? = bounce == .none
            ? nil : engine.recoverySegmentACostSecondsForTesting
        let segmentB = engine.startPlayersScheduleCostSecondsForTesting
        let lead = engine.lastStartLeadSecondsForTesting
        let restartsAfter = engine.recoveryRestartCountForTesting

        // m23-bs-3a §14.8 — THE `n >= 6` OBSERVATION, AND IT IS AN OBSERVATION,
        // NOT A REGRESSION GUARD. Every bs-2 and bs-3a live green ran in the
        // lead-FLOOR regime (n = 0 at L1/L4, n = 1 at L3 and at A-L1′), so below
        // 6 players the lead is pinned at 0.06 and the `0.008·n` scaling term has
        // never been seen doing work in a live run. This suite's realistic
        // project (8 tracks / 32 clips / 16 audio players) is the only ≥ 6-player
        // live fixture in the tree, and it is env-gated OFF by default — so this
        // line costs ZERO default-run sessions and zero new fixtures.
        //
        // ⚠️ THE GUARDS ARE ELSEWHERE AND STAY THERE: `StartAnchorBudgetTests`
        // owns the FORMULA (headless, exact, at every n) and the horizon
        // read-back in `RecoveryAnchorContinuityGateTests` / `EngineRebuildTests`
        // owns the identity (exact at ANY n). What was missing was evidence that
        // the scaling term ever RAN live, and an assertion is not the right shape
        // for that — a printed, dated number is.
        if bounce != .none {
            print("[measured] m23-bs-3 shape=\(shape.rawValue) bounce=\(bounce.rawValue)"
                  + " n=\(engine.lastContinuationPlayerCountForTesting)"
                  + " lead=" + String(format: "%.4f", lead) + "s"
                  + " horizon="
                  + String(format: "%.4f", engine.lastContinuationHorizonSecondsForTesting) + "s"
                  + " continuations=\(engine.continuationStartCountForTesting)"
                  + " overruns=\(engine.continuationOverrunCountForTesting)"
                  + " worstOverrun="
                  + String(format: "%.4f", engine.lastContinuationOverrunSecondsForTesting) + "s"
                  + " clampDowns=\(engine.continuationClampDownCountForTesting)")
        }

        try await Task.sleep(for: .milliseconds(Self.observeMs))
        engine.stopPlayback()

        // ⚠️ An empty sample set reaches the caller as `pushes=0 ⚠️STARVED`; it
        // is NEVER returned as nil. nil means "no output device" and nothing
        // else (the `prepare()` catch above) — see the header.
        let lag = { (sample: (ms: Double, beat: Double)) in
            sample.ms * Self.beatsPerMillisecond - sample.beat
        }
        let before = samples.filter { $0.ms <= mark }
        let after = samples.filter { $0.ms > mark }
        var worstLag = 0.0
        for sample in after { worstLag = max(worstLag, lag(sample)) }

        // Settled windows. BEFORE: the last `settleMs` of the roll, past the
        // initial lead-in ramp where the playhead is still clamped at the start
        // beat. AFTER: everything from `settleMs` past the mark, by which point
        // the new anchor (at most A + B + lead ≈ 0.2 s away) has certainly
        // passed and the playhead is advancing against it again.
        let settle = Double(Self.settleMs)
        let settledBefore = before.filter { $0.ms >= mark - settle }.map(lag)
        let settledAfter = after.filter { $0.ms >= mark + settle }.map(lag)

        return Split(shape: shape, bounce: bounce, segmentA: segmentA, segmentB: segmentB,
                     lead: lead, initialSegmentB: initialSegmentB, initialLead: initialLead,
                     restartsBefore: restartsBefore, restartsAfter: restartsAfter,
                     pushesBeforeMark: before.count, pushesAfterMark: after.count,
                     maxLagBeats: worstLag,
                     settledLagBeforeBeats: Self.median(settledBefore),
                     settledLagAfterBeats: Self.median(settledAfter))
    }

    /// Device context for the residual (finding 4 in the header).
    ///
    /// The three seams do not explain the whole backward step; a constant
    /// ~13 ms is left over. The first hypothesis a reader will have is a fixed
    /// CLOCK-BASIS offset — but the second is the OUTPUT BUFFER, and those two
    /// have opposite consequences for m23-bs-2: a clock-basis offset is a
    /// constant that can be subtracted, while a buffer-derived term SCALES with
    /// the user's I/O buffer size (a 2048-frame buffer would be ~43 ms at 48 k)
    /// and any budget keyed to it must be adaptive. Printing the device's own
    /// numbers next to the residual lets bs-2 tell them apart instead of
    /// inheriting "13 ms" as a constant.
    ///
    /// Read-only: nothing here WRITES a device property, and the throwaway
    /// engine is strictly less invasive than the real ones this suite starts.
    private static func deviceContext() -> String {
        let probe = AVAudioEngine()
        let latency = probe.outputNode.presentationLatency
        let rate = probe.outputNode.outputFormat(forBus: 0).sampleRate
        var frames: UInt32 = 0
        if let deviceID = HardwareDevices.defaultDeviceID(.output) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSize,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var size = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &frames)
        }
        let bufferSeconds = rate > 0 ? Double(frames) / rate : 0
        return "presentationLatency=" + String(format: "%.4f", latency) + "s"
            + " bufferFrames=\(frames)"
            + " bufferSeconds=" + String(format: "%.4f", bufferSeconds) + "s"
            + " rate=" + String(format: "%.0f", rate)
    }

    /// Runs all three bounce shapes for one project and prints one
    /// `[measured] m23-bs-1 …` line each. nil ⇒ no output device.
    private func sweep(_ shape: Shape) async throws -> [Split]? {
        print("[measured] m23-bs-1 device: \(Self.deviceContext())")
        var splits: [Split] = []
        for bounce in [Bounce.none, .recoverOnly, .watchdog] {
            guard let split = try await measure(shape, bounce) else { return nil }
            print("[measured] m23-bs-1 \(split.rendered)")
            splits.append(split)
        }
        return splits
    }

    // MARK: - Leg 1: the one-clip fixture (comparable to the handed baseline)

    @Test("live: segment split on the one-clip fixture")
    func oneClipSplit() async throws {
        if Self.announceSkipIfGated("one-clip legs") { return }
        guard let splits = try await sweep(.oneClip) else {
            print("[measured] m23-bs-1: NO OUTPUT DEVICE — one-clip legs skipped")
            return
        }

        for split in splits {
            let why = "seam did not fire on \(split.bounce.rawValue): " + split.rendered
            // Every leg starts playback at least once, so B and the lead are
            // always written.
            #expect(split.segmentB > 0, "\(why)")
            #expect(split.lead >= 0.06, "\(why)")
            #expect(split.initialSegmentB > 0, "\(why)")

            switch split.bounce {
            case .none:
                // Nothing restarted anything: the post-mark reading must be the
                // pre-mark reading, bit for bit. A property witness, not a
                // timing one — if these ever differ, something started players
                // behind the fixture's back and every A/B reading here is
                // attributed to the wrong call.
                #expect(split.segmentB == split.initialSegmentB, "\(why)")
                #expect(split.lead == split.initialLead, "\(why)")
                #expect(split.restartsAfter == split.restartsBefore, "\(why)")
            case .recoverOnly:
                #expect(split.segmentA != nil, "\(why)")
                #expect((split.segmentA ?? 0) > 0, "\(why)")
                // The `if !engine.isRunning` guard: a healthy engine is NOT
                // bounced, so this leg carries no prepare()/start() at all —
                // which is what makes it the isolator for everything else.
                let bounced: String = "recoverOnly took the RESTART branch — this leg no "
                    + "longer isolates the non-restart cost. " + split.rendered
                #expect(split.restartsAfter == split.restartsBefore, "\(bounced)")
            case .watchdog:
                #expect(split.segmentA != nil, "\(why)")
                #expect((split.segmentA ?? 0) > 0, "\(why)")
                let unbounced: String = "watchdogRestart did not take the RESTART branch — the "
                    + "prepare()/start() term is missing from this reading. " + split.rendered
                #expect(split.restartsAfter == split.restartsBefore + 1, "\(unbounced)")
            }
        }
    }

    // MARK: - Leg 2: the realistic project — THE leg this gate exists for

    @Test("live: segment split on a ~30-clip / 8-track project (half audio)")
    func realisticProjectSplit() async throws {
        if Self.announceSkipIfGated("realistic-project legs") { return }
        guard let splits = try await sweep(.realistic) else {
            print("[measured] m23-bs-1: NO OUTPUT DEVICE — realistic-project legs skipped")
            return
        }

        for split in splits {
            let hollow = "ANTI-VACUITY FAILURE: the realistic project's post-cap lead is at the "
                + "0.06 s floor, so NO audio players were pending — `prepareAllPlayers` was a "
                + "no-op and `startablePlayerCount` was 0. This leg measured a MIDI-only "
                + "project and says nothing about segment B's scaling, which is the entire "
                + "reason it exists. Check that the audio clips still resolve their fixture "
                + "files and still sit in the FUTURE relative to the resume beat. "
                + split.rendered
            #expect(split.lead > 0.0601, "\(hollow)")
            #expect(split.initialLead > 0.0601, "\(hollow)")
            #expect(split.segmentB > 0, "\(hollow)")
        }
    }
}
