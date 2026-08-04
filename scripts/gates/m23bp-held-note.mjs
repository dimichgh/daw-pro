// m23-bp gate — THE HELD NOTE: a mid-playback CONTINUATION reschedule must
// not permanently silence a note that was already sounding.
//
// ⚠️ STATUS (updated m23-bp-2, 2026-08-02): m23-bp IS FIXED — `RescheduleCause`
// (m23-bp-1, DONE) landed and is source-pinned. EVERY leg in this file is
// expected GREEN. A red leg here is a REGRESSION, not a reproduction — do
// NOT relabel a newly-red leg "expected" without investigating first. (This
// file itself did exactly that once: a stale "EXPECTED RED" label on the Act
// 2 held-note leg survived past the fix landing and was caught only at the
// m23-bp-2 review — the precise inverse of the hazard this note warns
// against. If a leg goes red, assume a real regression until proven
// otherwise.)
//
// THE BUG, AS IT WAS (historical — fixed by m23-bp-1, kept for context; this
// is no longer the current source). `MIDISchedule.buildEvents` used to
// unconditionally drop BOTH the note-on and note-off of any note whose onset
// preceded the reschedule point `fromBeat` — equivalent to:
//
//     guard onBeat >= fromBeat else { continue }  // no chase v0
//
// Pure-function measurement at the time: a 128-beat note built with
// `fromBeat: 4` -> 0 events; the same clip from `fromBeat: 0` -> 2 events.
// Any mid-playback reschedule therefore permanently silenced every note that
// was already sounding, because that note's onset is necessarily in the past
// relative to the new `fromBeat`.
//
// THE FIX, AS SHIPPED. `RescheduleCause` (Sources/DAWEngine/RescheduleCause.swift)
// is threaded WITHOUT A DEFAULT through every `restart`/`startPlayers` call —
// the compiler, not a comment, enumerates every reschedule site. `.relocation`
// (a CHOSEN beat: start, seek, record, loop-wrap) keeps the v0 no-chase rule.
// `.continuation` (the beat playback would have reached anyway — nothing was
// "chosen") now CHASES: a note whose onset is behind `fromBeat` but whose OFF
// is still ahead of it is re-admitted with its onset clamped to `fromBeat`.
// `chasesHeldNotes` has exactly ONE read in the tree — `PlaybackGraph.swift:2582`.
//
// THE TRIGGER ACT 1/2 BELOW USE (reconcile-during-playback). Currently
// `AudioEngine.tracksDidChangeBody`, `AudioEngine.swift:1064-1070` — line
// numbers in this hot file drift release to release (already shifted twice
// since this gate was written); anchor on the SYMBOL, not the line:
//
//     if changed, isRunning, let anchor = currentAnchor {
//         restart(fromBeat: derivedBeats(), tempoMap: anchor.tempoMap,
//                 cause: .continuation)
//     }
//
// fires whenever `PlaybackGraph.reconcile` reports `changed` WITHOUT setting
// `needsEngineRebuild` — i.e. a structural change cheap enough not to need a
// whole-engine rebuild. `restart` -> `stopAllPlayers` + `startPlayers` ->
// `graph.scheduleAll(fromBeat: derivedBeats(), cause: .continuation, …)`,
// which is what calls `MIDISchedule.buildEvents` with `fromBeat` pinned at
// the CURRENT playhead — exactly the mid-playback reschedule the bug used to
// break, and exactly the site whose chase this gate proves live.
//
// m23-bp-2 (CYCLE B, this revision) ADDS three more `.continuation` sites,
// each proven live with its OWN real user action through the control port —
// see ACT 3 (setTempo), ACT 4 (loopChanged) and ACT 5 (recoverEngine) below.
// Two more source-pinned `.continuation` sites are DELIBERATELY NOT covered
// here — see "WHAT THIS GATE CANNOT PROVE".
//
// ⚠️ ACT 1/2 ARE NOT A DEVICE FLIP. The roadmap filing blamed a device-flip
// path; ACT 5 below now covers a device-RATE trigger, but ACT 1/2's own
// trigger is unrelated to any device — it uses the cheapest structural
// change that reaches `tracksDidChangeBody`'s restart (see THE TRIGGER,
// above) without a rebuild: adding a bare instrument track (no clip, no assigned
// instrument — default kind is the built-in `.polySynth`, so this needs no
// AU host and no async prepare). Traced, not live-instrumented, through:
//   • PlaybackGraph.swift:947-950 "Note edits change the signature
//     (reschedule via restart) but never rebuild nodes."
//   • PlaybackGraph.swift:996-1010 "instrument-strip birth on a running
//     engine does NOT announce" (no rebuild).
//   • PlaybackGraph.swift:1033-1036 a fresh, trivially-routed source node
//     (master out, no sends) is "the ONE live-proven case" that wires
//     without announcing.
//   • PlaybackGraph.swift:1129-1132 `changed = newSignature != signature ||
//     newInstrumentSignature != instrumentSignature || …` — the new track's
//     appearance alone flips `changed` to true for the WHOLE pass, so every
//     instrument track's clips are rebuilt through `scheduleAll`, not just
//     the one that changed. This is exactly the roadmap's "every note that
//     was sounding" — the trigger need not touch the victim track at all.
//
// FIXTURE SHAPE — TWO SEQUENTIAL, SINGLE-TRACK ACTS, not one shared project.
// `MasterMixAnalyzer.swift:95-96`: "Peak-hold release: −20 dB per second."
// That is an order of magnitude slower than the ~1 s energy-smoothing decay
// quoted elsewhere in that file for the RMS/band fields — a peak sitting at
// a typical single-voice level (roughly −6…−20 dB observed on comparable
// fixtures elsewhere in this gate suite) takes several seconds to *ballistically*
// reach the −80 floor even once its source has gone dead silent. Two tracks
// sharing one master tap would make that decay tail indistinguishable from
// genuine audibility for several seconds after either one changes state —
// exactly the ambiguity a positive-control leg exists to rule out. Running
// the control and the defect as separate single-track acts means the ONLY
// thing that can move the master tap in either act is that act's own track,
// so the decay-tail behaviour becomes a diagnostic (a decaying-then-floored
// peak IS what permanent silence looks like on this meter) rather than a
// confound. Documented here so a reader does not mistake the two-act split
// for a weaker test than one shared project would be — it is the stronger
// one, given how this meter is built.
//
// ACT 1 — POSITIVE CONTROL / ANTI-VACUITY (must be green, or nothing below
// means anything). A track playing short repeating notes (0.1-beat spacing,
// well under the note-schedule gap the bug can open at typical tempos)
// undergoes the SAME KIND of structural change and must stay continuously
// audible across it — future notes (onset >= the new fromBeat) are
// unaffected by the guard, only past ones are dropped.
//
// ACT 2 — THE DEFECT + PERMANENCE (name kept for history; on the current,
// fixed tree this is a REGRESSION CHECK, not a reproduction). A single long
// note (128 beats, matching the headless measurement's own fixture) is
// voiced on a FLAT-SUSTAINING patch (GM program 19, Church Organ —
// deliberately not a decaying/plucked voice, so a floored reading can only
// mean the schedule dropped the note, never that the instrument's own
// envelope simply finished; the pre-trigger assertion is on minDB, i.e. the
// whole window, to prove the trace is flat rather than already sloping
// through the audible threshold). It is continuously audible before the
// structural change and, per the FIX now shipped, must be audible again by
// the LATE window (t >= LATE_WINDOW_MS, past worst-case peak-hold decay so
// this is not a meter-ballistics read) of a >=12 s window following it.
// Pre-fix, it was not: its onset (beat 0) is necessarily before
// `derivedBeats()` at the moment of the change, so both its events used to
// be dropped and it never sounded again. `RescheduleCause.continuation`'s
// chase now re-admits it.
//
// TRANSPORT FREEZE (m23-bq echo, historical framing corrected m23-bp-2). Acts
// 1-4 poll `project.overview` across the change and report how long
// `transport.positionBeats` takes to advance again. m23-bq's root is a
// DIFFERENT, now also FIXED, defect (m23-bq-1, DONE): `recoverEngine` used to
// trust a stale render clock across an engine bounce. Acts 1-4 use a plain
// `restart()` (no engine bounce, `renderClockTrusted: true`), so the code
// trace predicts no freeze there regardless of bq's status. ACT 5
// (recoverEngine) DOES bounce the engine and DOES pass `renderClockTrusted:
// false` post-bq-fix, so no freeze is predicted there either — but that is
// bq's property, not bp's, so ACT 5 reports it as a diagnostic only and does
// not assert on it; asserting it here would misattribute a bq regression to
// this gate. The gate reports the measured number either way.
//
// WHAT THIS GATE CANNOT PROVE:
//   • The two remaining source-pinned `.continuation` sites: routing rewire
//     (`AudioEngine.tracksDidChangeBody`, currently `:1121`) and the
//     `rebuildEngine` resume (currently `:1336`) — which is the device-FLIP
//     path (switching output devices) the ORIGINAL m23-bp report actually
//     described, distinct from ACT 5's device-RATE change below. DELIBERATELY
//     deferred at m23-bp-2: both read `resumeAfterRoutingRewire`
//     (`AudioEngine.swift:569`) and the `AnchorLine` type (`:209`), which are
//     m23-bs-3a's construction — in the tree but UNAUTHORISED, awaiting the
//     user's keep-or-revert ruling. A gate leg against a path that may be
//     deleted is worse than none (m23-bl: a leg that fails for a reason
//     unrelated to what it was built to catch). Both legs return free once
//     the user rules either way.
//   • Sub-second precision on the "silenced" moment — the master tap's own
//     20 dB/s release ballistics smear that boundary by design; the LATE
//     window (t >= 6000 ms post-trigger) is chosen to sit past worst-case
//     decay from any level this fixture is likely to reach, and is reported
//     as the clean diagnostic, but is not a claim about the exact instant.
//   • Anything about punch recording or count-in — no act engages either.
//
// AUDIBLE? NO. Output is pinned to BlackHole (a silent virtual device)
// before any transport starts, exactly as m20-e's L1 does; the pin is
// app-local and the macOS system default output is read before and after
// and never moved. ACT 5 (recoverEngine) DOES touch BlackHole's nominal
// sample rate (the only way to raise a real `AVAudioEngineConfigurationChange`
// without touching the user's actual devices) and restores it to 48000 with
// a read-back-verified leg, both at its own tail and as a best-effort
// `finally` safety net. Acts 1-4 touch no device rate.
//
// HOW TO RUN — ACT 5 needs the device-rate helper shared with m20-d/m20-e.
// The binary is gitignored; on a fresh checkout this aborts (exit 2) until
// you compile it:
//
//     swiftc -O scripts/gates/m20d-bhrate.swift -o scripts/gates/m20d-bhrate
//     node scripts/gates/m23bp-held-note.mjs
//
// Staging: DAW_CONTROL_PORT=17695. The user's live app on 17600 is never a
// target — `startStaging`/`connect` assert this.
import { sleep, buildOrAbort, startStaging, stopStaging, connect, ROOT } from "./_staging.mjs";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";

const GATE = "m23bp-held-note";
const UID = "BlackHole2ch_UID";
const STAGING_LOG = `/tmp/daw-gate-out/${GATE}/staging.log`;

const AUDIBLE_DB = -40;     // matches the m20-e convention for "clearly sounding"
const FLOOR_ISH_DB = -65;   // conservative slack around the exact −80 house floor
const LATE_WINDOW_MS = 6000; // past worst-case peak-hold decay (see header)

const SETTLE_AFTER_INSTRUMENT_MS = 1000;
const SETTLE_AFTER_PLAY_MS = 2000;
const PRE_TRIGGER_WINDOW_MS = 1500;
const ACT1_POST_TRIGGER_WINDOW_MS = 9000;
const ACT2_POST_TRIGGER_WINDOW_MS = 12000; // >= the ~10 s the roadmap item asks for

// ── m23-bp-2 ACT 5 (recoverEngine) only. Shared with m20-d/m20-e: SOURCE is
// committed (`m20d-bhrate.swift`), the compiled binary is a build artifact
// and is not. It can only ever resolve BlackHole — `TARGET_UID` is a
// compile-time constant with no argument that overrides it — so it cannot
// reach the user's real devices.
const BHRATE = path.join(ROOT, "scripts", "gates", "m20d-bhrate");
const PROJECT_RATE = 48000;
const STAGED_DEVICE_RATE = 44100;   // ACT 5's flip target — any value != 48000 works
const RESTORE_RATE = 48000;
if (!existsSync(BHRATE)) {
  console.log(`ABORT — device-rate helper missing: ${BHRATE}`);
  console.log("       build it:  swiftc -O scripts/gates/m20d-bhrate.swift -o scripts/gates/m20d-bhrate");
  process.exit(2);
}
const bhrate = (...args) => execFileSync(BHRATE, args, { encoding: "utf8" }).trim();
const readBackOf = s => { const m = /read-back=([0-9.]+)/.exec(s); return m ? Number(m[1]) : NaN; };

let pass = 0, fail = 0, skipped = 0;
const ck = (name, cond, extra) => {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; console.log("FAIL " + name + (extra !== undefined ? " :: " + extra : "")); }
};
/// A failed PRECONDITION must SKIP-AND-REPORT, never silently pass and never
/// silently fail as though the mechanism under test was exercised (m23-bl:
/// a failed precondition certifying its dependents as PASS is a corpus bug
/// this file must not repeat). Neither pass nor fail is incremented — a
/// SKIP is its own outcome, printed loudly, and the run-summary reports it
/// separately from pass/fail so it cannot be miscounted as either.
const skip = (name, reason) => { skipped++; console.log("SKIP " + name + " :: " + reason); };

let ws;
let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `bp${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 25000);
    const h = ev => {
      const m = JSON.parse(ev.data);
      if (m.id !== i) return;
      clearTimeout(t); ws.removeEventListener("message", h); res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id: i, command, params }));
  });
}

const devicesOf = r => r.result?.devices ?? [];
const defaultUID = ds => (ds.find(d => d.isDefault) ?? {}).uid ?? null;
const bhOf = ds => ds.find(d => d.uid === UID) ?? {};

/// Cycles three reads per tick: master-tap peak, transport position, engine
/// perf stats — so one window yields all three data series over the SAME
/// span with no separate polling loop to keep in sync. `intervalMs: 0` is
/// hammer mode (no sleep between ticks, ~sub-ms RTT on this machine per the
/// m20-e measurement of the same shape); longer windows pass a small
/// interval to keep the request volume sane without losing the resolution
/// these assertions need (all are on a >=100 ms scale).
async function monitor(label, ms, { intervalMs = 0 } = {}) {
  const t0 = Date.now();
  const peaks = [];      // {t, db}
  const positions = [];  // {t, beat}
  let perfReads = 0, lastCallbacks = -1, callbackGrowth = false;
  let k = 0;
  while (Date.now() - t0 < ms) {
    const t = Date.now() - t0;
    const slot = k % 3;
    if (slot === 0) {
      const m = await cmd("mixer.masterAnalysis");
      const p = m.result?.peakDB;
      if (Number.isFinite(p)) peaks.push({ t, db: p });
    } else if (slot === 1) {
      const o = await cmd("project.overview");
      const b = o.result?.transport?.positionBeats;
      if (Number.isFinite(b)) positions.push({ t, beat: b });
    } else {
      const p = (await cmd("engine.performanceStats")).result ?? {};
      perfReads++;
      if (Number.isFinite(p.callbackCount)) {
        if (lastCallbacks >= 0 && p.callbackCount > lastCallbacks) callbackGrowth = true;
        lastCallbacks = p.callbackCount;
      }
    }
    k++;
    if (intervalMs) await sleep(intervalMs);
  }
  const dbs = peaks.map(s => s.db);
  const minDB = dbs.length ? Math.min(...dbs) : NaN;
  const maxDB = dbs.length ? Math.max(...dbs) : NaN;
  const lateD = peaks.filter(s => s.t >= LATE_WINDOW_MS).map(s => s.db);
  const lateMax = lateD.length ? Math.max(...lateD) : NaN;
  const firstAudible = peaks.find(s => s.db > AUDIBLE_DB);
  const lastAudible = [...peaks].reverse().find(s => s.db > AUDIBLE_DB);
  console.log(`  [${label}] ${peaks.length} peak samples over ${ms}ms `
    + `(${Number.isFinite(minDB) ? minDB.toFixed(1) : "n/a"}…${Number.isFinite(maxDB) ? maxDB.toFixed(1) : "n/a"} dB, `
    + `late[t>=${LATE_WINDOW_MS}] max=${Number.isFinite(lateMax) ? lateMax.toFixed(1) : "n/a"} dB) `
    + `firstAudible=${firstAudible ? firstAudible.t + "ms" : "never"} `
    + `lastAudible=${lastAudible ? lastAudible.t + "ms" : "never"} `
    + `${positions.length} position samples, perfReads=${perfReads} callbackGrowth=${callbackGrowth}`);
  return { peaks, positions, minDB, maxDB, lateMax, firstAudible, lastAudible, callbackGrowth, perfReads };
}

/// From a `monitor()` result, the ms-since-window-start at which the
/// transport position first moved past `fromBeat + 0.05`, or null if it
/// never did inside the window — the "freeze duration" measurement for the
/// m23-bq echo.
function freezeReport(result, fromBeat) {
  const hit = result.positions.find(p => p.beat > fromBeat + 0.05);
  return hit ? { advanced: true, ms: hit.t, to: hit.beat } : { advanced: false, ms: null, to: null };
}

/// m23-bp-2 — THE ONE HOME for the "held-note defect" measurement shape used
/// by ACTs 3/4/5b (ACT 1/2 stay inline/untouched — historical, and Act 1's
/// control shape differs). Builds ONE single-track fixture (a 128-beat note
/// on a flat-sustaining GM organ patch, exactly ACT 2's fixture — see the
/// header for why: an organ's own envelope cannot explain a post-trigger
/// floor, only the schedule can), plays it, asserts it is CONTINUOUSLY
/// audible before `trigger()` fires the site under test, then asserts it is
/// audible again by the LATE window after.
///
/// `beforePlay` (optional): runs after the clip is built, before
/// `transport.seek`/`play` — for sites (loopChanged) whose trigger depends
/// on state established BEFORE the transport starts. Returns `{ok, detail}`;
/// `ok: false` marks the act's precondition failed.
/// `trigger` (required): the real user action under test. Returns
/// `{ok, detail}`; `ok: false` ALSO marks the precondition failed — a wire
/// call that did not do what it claims must not be trusted to have reached
/// the site being measured.
/// When the precondition fails, the RECOVERY and FREEZE legs SKIP-AND-REPORT
/// (m23-bl: a failed precondition must never certify a dependent as PASS)
/// rather than asserting on a run that never exercised the intended path.
/// `assertFreeze`: true for a plain `restart()` (no engine bounce — A1/A2's
/// own prediction applies); false for a real engine bounce (recoverEngine),
/// where "no freeze" is m23-bq's property, not this gate's, and asserting it
/// here would misattribute a bq regression to bp.
async function runHeldNoteAct(label, { beforePlay, trigger, assertFreeze, postWindowMs = ACT2_POST_TRIGGER_WINDOW_MS }) {
  let r = await cmd("project.new", { discardChanges: true });
  ck(`${label} project.new ok (fresh project — no leftover state from a previous act)`, r.ok, JSON.stringify(r.error));

  r = await cmd("output.setDevice", { uid: UID });
  ck(`${label} output pin still held into this act`, r.ok && bhOf(devicesOf(r)).isSelected === true, JSON.stringify(r.error));

  r = await cmd("track.add", { kind: "instrument", name: "Held" });
  const heldId = (r.result?.track ?? r.result)?.id;
  ck(`${label} held track added`, !!heldId, JSON.stringify(r));

  // GM program 19 = Church Organ — see ACT 2's header rationale, verbatim
  // here: a flat-sustaining patch means a post-trigger floor can only mean
  // the schedule dropped the note, never that its own envelope finished.
  r = await cmd("track.setInstrument", { trackId: heldId, soundBank: { source: "gm", program: 19 } });
  ck(`${label} held instrument assigned (GM bank, flat-sustaining organ patch)`, r.ok, JSON.stringify(r.error));
  console.log(`  [${label}] resolved instrument: ${r.result?.soundBank?.name ?? "?"}`);
  await sleep(SETTLE_AFTER_INSTRUMENT_MS);

  const heldNotes = [{ pitch: 64, velocity: 100, startBeat: 0, lengthBeats: 128 }];
  r = await cmd("clip.addMIDI", { trackId: heldId, atBeat: 0, lengthBeats: 128, name: "Held", notes: heldNotes });
  ck(`${label} held clip added (one 128-beat note, matching the headless measurement's fixture)`,
     r.ok && r.result?.notes?.length === 1, JSON.stringify(r.error ?? r.result));

  let preconditionOk = true, preconditionDetail = "";
  if (beforePlay) {
    const p = await beforePlay();
    ck(`${label} PRECONDITION before play`, p.ok, p.detail ?? "");
    if (!p.ok) { preconditionOk = false; preconditionDetail = p.detail ?? "beforePlay precondition failed"; }
  }

  r = await cmd("transport.seek", { beats: 0 });
  ck(`${label} transport.seek(0) ok`, r.ok, JSON.stringify(r.error));
  r = await cmd("transport.play");
  ck(`${label} transport.play ok`, r.ok, JSON.stringify(r.error));
  await sleep(SETTLE_AFTER_PLAY_MS);

  let h = await monitor(`${label} pre-trigger baseline`, PRE_TRIGGER_WINDOW_MS);
  ck(`${label} LEG (before) — held note is CONTINUOUSLY audible BEFORE the trigger (flat organ `
     + `trace — see ACT 2's rationale for why this proves a later floor means dropped, not decayed)`,
     h.minDB > AUDIBLE_DB, `min/max ${h.minDB.toFixed(1)}/${h.maxDB.toFixed(1)} dB`);
  ck(`${label} pre-trigger: render callbacks flowing`, h.callbackGrowth && h.perfReads > 0,
     `growth=${h.callbackGrowth} reads=${h.perfReads}`);

  let ov = await cmd("project.overview");
  const preBeat = ov.result?.transport?.positionBeats ?? 0;
  console.log(`  [${label}] beat at trigger: ${preBeat.toFixed(2)}`);

  // ── THE TRIGGER — the real user action under test ────────────────────────
  const t = await trigger();
  ck(`${label} TRIGGER accepted`, t.ok, t.detail ?? "");
  if (!t.ok) { preconditionOk = false; preconditionDetail = t.detail ?? "trigger precondition failed"; }

  h = await monitor(`${label} post-trigger (LEG must recover)`, postWindowMs, { intervalMs: 5 });
  if (preconditionOk) {
    ck(`${label} ⚠️ REQUIRED GREEN POST-FIX (m23-bp is fixed — a red leg here is a REGRESSION, `
       + `not the reproduction) — the held note MUST be audible again by the LATE window `
       + `(t>=${LATE_WINDOW_MS}ms, past worst-case peak-hold decay) following the trigger`,
       h.lateMax > AUDIBLE_DB,
       `late[t>=${LATE_WINDOW_MS}] max ${Number.isFinite(h.lateMax) ? h.lateMax.toFixed(1) : "n/a"} dB `
       + `(whole-window min/max ${h.minDB.toFixed(1)}/${h.maxDB.toFixed(1)} dB)`);
  } else {
    skip(`${label} REQUIRED GREEN POST-FIX recovery`, preconditionDetail);
  }
  ck(`${label} post-trigger: render callbacks kept flowing (rules out a dead render thread as `
     + `the explanation for either outcome)`, h.callbackGrowth, `reads=${h.perfReads}`);

  const freeze = freezeReport(h, preBeat);
  console.log(`  [${label}] transport freeze report: ${freeze.advanced
    ? `advanced ${preBeat.toFixed(2)} -> ${freeze.to.toFixed(2)} after ${freeze.ms} ms`
    : `NO advance observed within ${postWindowMs} ms`}`);
  if (!preconditionOk) {
    skip(`${label} transport freeze`, preconditionDetail);
  } else if (assertFreeze) {
    ck(`${label} transport position resumed advancing after the trigger (a plain restart(), no `
       + `engine bounce — no freeze predicted, same class as A1/A2)`, freeze.advanced, JSON.stringify(freeze));
  } else {
    console.log(`  [${label}] freeze diagnostic NOT asserted — that is m23-bq's property, not `
      + `this gate's; asserting it here would misattribute a bq regression to bp.`);
  }

  r = await cmd("transport.stop");
  ck(`${label} transport.stop ok`, r.ok, JSON.stringify(r.error));

  return { heldId, preBeat, preconditionOk };
}

// ── L0: stage the loopback at the project rate BEFORE anything is built ─────
// (m20-e's L0 shape) — so ACT 5's flip has a known, consistent baseline and
// Acts 1-4 never run against a stray leftover rate from a prior gate.
console.log("device rate before staging:", bhrate());
const baseStaged = bhrate(String(PROJECT_RATE));
console.log(`staged -> ${baseStaged}`);
ck("L0 loopback staged at 48000 (every rate leg below is measured against this baseline)",
   readBackOf(baseStaged) === PROJECT_RATE, baseStaged);

buildOrAbort({ label: "building staging binary (m23bp)…" });
startStaging({ gate: GATE, detached: true, logPath: STAGING_LOG });

let systemDefault = null;
try {
  ws = await connect();
  await sleep(1500);

  // ── L1: pin the loopback BEFORE any transport starts (m20-e's L1 shape) ──
  let r = await cmd("output.listDevices");
  const initial = devicesOf(r);
  systemDefault = defaultUID(initial);
  ck("L1 a system default exists (the baseline the safety leg is measured against)",
     systemDefault !== null, JSON.stringify(initial));
  ck("L1 the loopback device is present", "uid" in bhOf(initial), JSON.stringify(bhOf(initial)));

  r = await cmd("project.new", { discardChanges: true });
  ck("L1 project.new ok (clean slate before pinning)", r.ok, JSON.stringify(r.error));
  r = await cmd("output.setDevice", { uid: UID });
  ck("L1 output pinned to the loopback (nothing below may reach the speakers)",
     r.ok && bhOf(devicesOf(r)).isSelected === true, JSON.stringify(r.error));

  // ── L2: THE DETECTOR IS NOT BLIND, part 1 — it can read the FLOOR ────────
  // No track exists yet and the transport has never played: the contract
  // ("headless (no engine) reads the floor snapshot") predicts the exact
  // −80 house floor here. This is the run's independent proof that a floor
  // reading later is not simply the analyzer failing to report anything.
  let floorPeak = -Infinity;
  for (let i = 0; i < 5; i++) {
    const m = await cmd("mixer.masterAnalysis");
    if (Number.isFinite(m.result?.peakDB)) floorPeak = Math.max(floorPeak, m.result.peakDB);
  }
  console.log(`  [L2] floor reading (max of 5 samples, nothing built yet): ${floorPeak.toFixed(1)} dB`);
  ck("L2 ⚠️ THE DETECTOR IS NOT BLIND — master tap reads the floor before any track exists "
     + "(everything below that reads a floor is meaningful only because of this)",
     floorPeak <= FLOOR_ISH_DB, `${floorPeak.toFixed(1)} dB`);

  // ═══════════════════════════════════════════════════════════════════════
  // ACT 1 — POSITIVE CONTROL. Repeating short notes, same trigger shape.
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n── ACT 1: positive control (repeating notes) ──");
  r = await cmd("project.new", { discardChanges: true });
  ck("A1 project.new ok", r.ok, JSON.stringify(r.error));

  r = await cmd("track.add", { kind: "instrument", name: "Control" });
  const ctrlId = (r.result?.track ?? r.result)?.id;
  ck("A1 control track added", !!ctrlId, JSON.stringify(r));

  r = await cmd("track.setInstrument", { trackId: ctrlId, soundBank: { source: "gm", program: 0 } });
  ck("A1 control instrument assigned (GM bank — never a 3rd-party AUv2)", r.ok, JSON.stringify(r.error));
  await sleep(SETTLE_AFTER_INSTRUMENT_MS); // let the AUSampler host finish its prepare

  // Repeating notes every 0.1 beat (50 ms at the default 120 BPM) — well
  // under any gap the schedule-drop guard could plausibly open, so a note
  // whose onset is still ahead of the reschedule point is always close by.
  const CTRL_STEP = 0.1, CTRL_NOTE_LEN = 0.08, CTRL_LEN_BEATS = 80;
  const ctrlNotes = [];
  for (let i = 0; i < CTRL_LEN_BEATS / CTRL_STEP; i++) {
    ctrlNotes.push({ pitch: 60, velocity: 100, startBeat: +(i * CTRL_STEP).toFixed(2), lengthBeats: CTRL_NOTE_LEN });
  }
  r = await cmd("clip.addMIDI", { trackId: ctrlId, atBeat: 0, lengthBeats: CTRL_LEN_BEATS, name: "Pulse", notes: ctrlNotes });
  ck("A1 control clip added with every note accepted", r.ok && r.result?.notes?.length === ctrlNotes.length,
     JSON.stringify(r.error ?? { got: r.result?.notes?.length, want: ctrlNotes.length }));

  r = await cmd("transport.seek", { beats: 0 });
  ck("A1 transport.seek(0) ok", r.ok, JSON.stringify(r.error));
  r = await cmd("transport.play");
  ck("A1 transport.play ok", r.ok, JSON.stringify(r.error));
  await sleep(SETTLE_AFTER_PLAY_MS);

  let h = await monitor("A1 pre-trigger baseline", PRE_TRIGGER_WINDOW_MS);
  ck("A1 pre-trigger: control audible", h.maxDB > AUDIBLE_DB, `max ${h.maxDB.toFixed(1)} dB`);
  ck("A1 pre-trigger: render callbacks flowing (a silent read is not evidence without this)",
     h.callbackGrowth && h.perfReads > 0, `growth=${h.callbackGrowth} reads=${h.perfReads}`);

  let ov = await cmd("project.overview");
  const a1PreBeat = ov.result?.transport?.positionBeats ?? 0;
  console.log(`  [A1] beat at trigger: ${a1PreBeat.toFixed(2)}`);

  // ── THE TRIGGER — a plain structural change while the transport rolls ───
  r = await cmd("track.add", { kind: "instrument", name: "Trigger1" });
  ck("A1 TRIGGER: bare instrument-track add accepted (the structural change; "
     + "no clip, no assigned instrument, default kind polySynth)", r.ok, JSON.stringify(r.error));

  h = await monitor("A1 post-trigger (POSITIVE CONTROL window)", ACT1_POST_TRIGGER_WINDOW_MS, { intervalMs: 5 });
  ck("A1 ⚠️ POSITIVE CONTROL / ANTI-VACUITY — control track stays CONTINUOUSLY audible "
     + "across the same structural change (if this is red, the fixture itself is broken "
     + "and no other leg in this gate means anything)",
     h.minDB > AUDIBLE_DB, `min ${h.minDB.toFixed(1)} dB over ${ACT1_POST_TRIGGER_WINDOW_MS}ms`);
  ck("A1 post-trigger: render callbacks kept flowing", h.callbackGrowth, `reads=${h.perfReads}`);

  const a1Freeze = freezeReport(h, a1PreBeat);
  console.log(`  [A1] transport freeze report: ${a1Freeze.advanced
    ? `advanced ${a1PreBeat.toFixed(2)} -> ${a1Freeze.to.toFixed(2)} after ${a1Freeze.ms} ms`
    : `NO advance observed within ${ACT1_POST_TRIGGER_WINDOW_MS} ms`}`);
  ck("A1 transport position resumed advancing after the structural change (m23-bq echo — "
     + "this trigger is a plain restart() with renderClockTrusted:true, not an engine bounce, "
     + "so the code trace predicts no freeze; reporting what actually happened)",
     a1Freeze.advanced, JSON.stringify(a1Freeze));

  r = await cmd("transport.stop");
  ck("A1 transport.stop ok", r.ok, JSON.stringify(r.error));

  // ═══════════════════════════════════════════════════════════════════════
  // ACT 2 — THE DEFECT. One long held note, same trigger shape.
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n── ACT 2: the defect (one 128-beat held note) ──");
  r = await cmd("project.new", { discardChanges: true });
  ck("A2 project.new ok (fresh project — no leftover state from Act 1)", r.ok, JSON.stringify(r.error));

  // Defensive re-pin: project.new only resets the domain model, but this
  // confirms the loopback is still the selected output before Act 2 plays.
  r = await cmd("output.setDevice", { uid: UID });
  ck("A2 output pin still held into Act 2", r.ok && bhOf(devicesOf(r)).isSelected === true, JSON.stringify(r.error));

  r = await cmd("track.add", { kind: "instrument", name: "Held" });
  const heldId = (r.result?.track ?? r.result)?.id;
  ck("A2 held track added", !!heldId, JSON.stringify(r));

  // GM program 19 = Church Organ. Deliberately NOT a decaying/plucked patch
  // (an EP or plucked-string voice's own envelope would fall through
  // AUDIBLE_DB on its own within the pre-trigger window, making the "still
  // audible after" assertion pass or fail for a reason that has nothing to
  // do with the bug — an organ sustains flat for as long as the note is
  // held, so a floor reading after the trigger can only mean the schedule
  // dropped the note, not that its own envelope ran out). Read the resolved
  // name back rather than trusting the program number in isolation.
  r = await cmd("track.setInstrument", { trackId: heldId, soundBank: { source: "gm", program: 19 } });
  ck("A2 held instrument assigned (GM bank, flat-sustaining organ patch)", r.ok, JSON.stringify(r.error));
  console.log(`  [A2] resolved instrument: ${r.result?.soundBank?.name ?? "?"}`);
  await sleep(SETTLE_AFTER_INSTRUMENT_MS);

  // The exact fixture shape from the headless measurement: one 128-beat note.
  const heldNotes = [{ pitch: 64, velocity: 100, startBeat: 0, lengthBeats: 128 }];
  r = await cmd("clip.addMIDI", { trackId: heldId, atBeat: 0, lengthBeats: 128, name: "Held", notes: heldNotes });
  ck("A2 held clip added (one 128-beat note, matching the headless measurement's fixture)",
     r.ok && r.result?.notes?.length === 1, JSON.stringify(r.error ?? r.result));

  r = await cmd("transport.seek", { beats: 0 });
  ck("A2 transport.seek(0) ok", r.ok, JSON.stringify(r.error));
  r = await cmd("transport.play");
  ck("A2 transport.play ok", r.ok, JSON.stringify(r.error));
  await sleep(SETTLE_AFTER_PLAY_MS);

  h = await monitor("A2 pre-trigger baseline", PRE_TRIGGER_WINDOW_MS);
  // minDB, not maxDB: an organ patch sustains flat while held, so the WHOLE
  // pre-trigger window must read audible, not just its peak sample. A
  // maxDB-only check would still pass on a fixture whose "before" reading is
  // actually decaying through the threshold — exactly the confound the
  // organ-patch swap above exists to avoid; this assertion is what proves
  // the swap worked (a flat trace), not just that SOME sample was loud.
  ck("A2 LEG 2 (before) — held note is CONTINUOUSLY audible BEFORE the structural change "
     + "(a flat trace, not a decaying one, is what makes the post-trigger floor mean the note "
     + "was dropped rather than that its own envelope simply finished)",
     h.minDB > AUDIBLE_DB, `min/max ${h.minDB.toFixed(1)}/${h.maxDB.toFixed(1)} dB`);
  ck("A2 ⚠️ THE DETECTOR IS NOT BLIND, part 2 — it can also read SIGNAL, in the same run as the L2 floor read",
     h.maxDB > AUDIBLE_DB, `max ${h.maxDB.toFixed(1)} dB`);
  ck("A2 pre-trigger: render callbacks flowing", h.callbackGrowth && h.perfReads > 0,
     `growth=${h.callbackGrowth} reads=${h.perfReads}`);

  ov = await cmd("project.overview");
  const a2PreBeat = ov.result?.transport?.positionBeats ?? 0;
  console.log(`  [A2] beat at trigger: ${a2PreBeat.toFixed(2)} (the held note's onset, beat 0, `
    + `is necessarily before this — the exact condition RescheduleCause.continuation now chases, `
    + `MIDISchedule.swift's chased-note branch, currently guarded around :172)`);

  // ── THE TRIGGER — identical shape to Act 1's ─────────────────────────────
  r = await cmd("track.add", { kind: "instrument", name: "Trigger2" });
  ck("A2 TRIGGER: bare instrument-track add accepted", r.ok, JSON.stringify(r.error));

  h = await monitor("A2 post-trigger (THE DEFECT + PERMANENCE window)", ACT2_POST_TRIGGER_WINDOW_MS, { intervalMs: 5 });
  // Asserted on the LATE window (t >= LATE_WINDOW_MS), not the whole 12s. The
  // early part of this window is inside the meter's own ~20 dB/s peak-hold
  // release tail from the pre-trigger level, so "never crosses AUDIBLE_DB
  // anywhere in the whole window" and "the late window specifically never
  // recovers" are NOT the same claim — only the second is free of meter
  // ballistics. The whole-window firstAudible/lastAudible figures are still
  // printed by monitor() above as a diagnostic, never asserted.
  ck("A2 ⚠️ REQUIRED GREEN POST-FIX (m23-bp is fixed — a red leg here is a REGRESSION, not "
     + "the reproduction) — LEG 2/3: the held note MUST be audible again by the LATE window "
     + "(t>=" + LATE_WINDOW_MS + "ms, past worst-case peak-hold decay, so this is not a "
     + "meter-ballistics artifact) following the structural change. Pre-fix, MIDISchedule.swift "
     + "used to drop both this note's on and off events because its onset precedes the new "
     + "fromBeat; `RescheduleCause.continuation` now chases it back in.",
     h.lateMax > AUDIBLE_DB,
     `late[t>=${LATE_WINDOW_MS}] max ${Number.isFinite(h.lateMax) ? h.lateMax.toFixed(1) : "n/a"} dB `
     + `(whole-window min/max ${h.minDB.toFixed(1)}/${h.maxDB.toFixed(1)} dB, `
     + `firstAudible=${h.firstAudible ? h.firstAudible.t + "ms" : "never"})`);
  ck("A2 post-trigger: render callbacks kept flowing (the silence is a scheduling defect, "
     + "not a dead render thread — rules out an engine hang as the explanation)",
     h.callbackGrowth, `reads=${h.perfReads}`);
  // NOT asserted (deliberately): after the fix lands this window must stay
  // audible throughout, so a floor reading here would legitimately disappear
  // post-fix — asserting it would make a correct fix look like a regression.
  // The independent, still-asserted floor proof is L2 (before any track
  // exists at all), which is unaffected by whether m23-bp is fixed.
  console.log(`  [A2] diagnostic (not asserted): post-trigger window touched the floor at some `
    + `point: ${h.minDB <= FLOOR_ISH_DB} (min ${h.minDB.toFixed(1)} dB) — expected true pre-fix, `
    + `expected false post-fix`);

  const a2Freeze = freezeReport(h, a2PreBeat);
  console.log(`  [A2] transport freeze report (m23-bq echo): ${a2Freeze.advanced
    ? `advanced ${a2PreBeat.toFixed(2)} -> ${a2Freeze.to.toFixed(2)} after ${a2Freeze.ms} ms`
    : `NO advance observed within ${ACT2_POST_TRIGGER_WINDOW_MS} ms`}`);
  ck("A2 transport position resumed advancing after the structural change (same prediction as "
     + "A1: this trigger does not bounce the engine, so no freeze is expected — reporting the "
     + "measured number regardless)",
     a2Freeze.advanced, JSON.stringify(a2Freeze));

  r = await cmd("transport.stop");
  ck("A2 transport.stop ok", r.ok, JSON.stringify(r.error));

  // ═══════════════════════════════════════════════════════════════════════
  // ACT 3 — setTempo (m23-bp-2). `AudioEngine.setTempo`, currently
  // `AudioEngine.swift:993`: `restart(fromBeat: beats, tempoMap:
  // transport.tempoMap, cause: .continuation)`. `ProjectStore.applyTempoChange`
  // calls `engine?.setTempo(transport)` UNCONDITIONALLY on every successful
  // `transport.setTempo`, and `AudioEngine.setTempo` restarts unconditionally
  // whenever `currentAnchor != nil` (i.e. while playing) — so a successful,
  // playing-time tempo change reaches this exact restart deterministically;
  // there is no extra guard that could make the trigger land vacuously, the
  // way ACT 4's loop-bounds guard can.
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n── ACT 3: setTempo while rolling (AudioEngine.swift:993) ──");
  const ACT3_BPM = 90; // default project tempo is 120 — a real, audible drag
  await runHeldNoteAct("A3", {
    assertFreeze: true, // plain restart(), no engine bounce — same class as A1/A2
    trigger: async () => {
      const rr = await cmd("transport.setTempo", { bpm: ACT3_BPM });
      // transport.setTempo echoes store.transport.tempoBPM directly as a
      // bare number (Commands.swift: `.success(request.id, .number(...))`).
      const echoed = rr.result;
      const ok = rr.ok && echoed === ACT3_BPM;
      return {
        ok,
        detail: `bpm -> ${JSON.stringify(echoed)} (wanted ${ACT3_BPM})`
          + (rr.ok ? "" : ` err=${JSON.stringify(rr.error)}`),
      };
    },
  });

  // ═══════════════════════════════════════════════════════════════════════
  // ACT 4 — loopChanged (m23-bp-2). `AudioEngine.loopChanged`, currently
  // `AudioEngine.swift:2288`: `restart(fromBeat: derivedBeats(), tempoMap:
  // anchor.tempoMap, cause: .continuation)` — but ONLY when `scheduledLoop`
  // (the loop window `startPlayers` captured into `loopContext` at the LAST
  // schedule) is non-nil AND the loop is being disabled or its bounds moved.
  // `loopContext` is set at scheduling time whenever the loop is ALREADY
  // enabled with `beats < loopEndBeat` — so the loop must be enabled BEFORE
  // `transport.play`, and the trigger must be a SECOND `transport.setLoop`
  // that moves the bounds while already enabled. This is a real conditional
  // guard (unlike ACT 3's unconditional restart), so both `transport.setLoop`
  // calls' STORE-level echoes are asserted as explicit preconditions — a wire
  // success whose readback does not match what was asked for is treated as a
  // precondition failure and SKIPs the recovery leg rather than certifying it
  // (m23-bl: a failed precondition must never pass its dependents).
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n── ACT 4: loopChanged while rolling (AudioEngine.swift:2288) ──");
  await runHeldNoteAct("A4", {
    assertFreeze: true, // plain restart(), no engine bounce — same class as A1/A2
    beforePlay: async () => {
      const rr = await cmd("transport.setLoop", { enabled: true, startBeat: 0, endBeat: 200 });
      const t = rr.result ?? {};
      const ok = rr.ok && t.isLoopEnabled === true && t.loopStartBeat === 0 && t.loopEndBeat === 200;
      return {
        ok,
        detail: `enable loop [0,200) -> ${JSON.stringify(t)}` + (rr.ok ? "" : ` err=${JSON.stringify(rr.error)}`),
      };
    },
    trigger: async () => {
      // Both bounds (200, then 150) sit far past anything reached in this
      // act's ~15 s wall-clock window at 120 BPM (~30 beats) — the loop
      // never wraps, so this exercises the BOUNDS-CHANGE restart, never the
      // gapless-wrap path (a different mechanism, out of scope here).
      const rr = await cmd("transport.setLoop", { enabled: true, startBeat: 0, endBeat: 150 });
      const t = rr.result ?? {};
      const ok = rr.ok && t.isLoopEnabled === true && t.loopEndBeat === 150;
      return {
        ok,
        detail: `move loop end 200 -> 150 -> ${JSON.stringify(t)}` + (rr.ok ? "" : ` err=${JSON.stringify(rr.error)}`),
      };
    },
  });

  // ═══════════════════════════════════════════════════════════════════════
  // ACT 5 — recoverEngine (m23-bp-2). `AudioEngine.recoverEngine`, currently
  // `AudioEngine.swift:3960`: `startPlayers(fromBeat: resume, tempoMap:
  // anchor.tempoMap, renderClockTrusted: false, cause: .continuation,
  // anchorPolicy: .atHostTime(anchorHost))` — reached via
  // `handleConfigurationChange()`, the observer for the real
  // `AVAudioEngineConfigurationChange` notification AVFoundation raises when
  // the CURRENTLY SELECTED device's hardware format changes under a running
  // engine. `recoverEngine` genuinely STOPS and RESTARTS the AVAudioEngine
  // (`engine.prepare(); try engine.start()`), unlike Acts 1/3/4's plain
  // `restart()` — the only act in this file exercising a real engine bounce.
  // Per m20-e's own established finding ("a bare device flip therefore gives
  // config-change -> restart -> startPlayers and NEVER re-enters
  // syncAudioUnitInstruments" / "recoverEngine does NOT call rebuildEngine",
  // m20e-flip-path.mjs), this trigger cannot land on the DEFERRED
  // routing-rewire/rebuildEngine-resume sites (see header) — a genuinely
  // different code path from `output.setDevice`-driven device SWITCHES.
  //
  // THE TRIGGER. There is no wire verb that moves a device's nominal sample
  // rate (deliberately — nothing user-facing should), so this act uses the
  // same `m20d-bhrate` helper m20-d/m20-e use to change BlackHole's OWN
  // nominal rate while it is the selected output — the only way to raise a
  // real HAL-level configuration-change notification without touching the
  // user's actual devices.
  //
  // ACT 5a — POSITIVE CONTROL, same shape as ACT 1 but across THIS specific
  // trigger. A real engine stop/start is more disruptive than a plain
  // restart() (m20-e measured the engine-restart segment alone at
  // 0.9-48 ms), so this exists to separate "the schedule dropped the note"
  // (ACT 5b) from "the device/converter glitches across a real HAL
  // reconfiguration" — a different failure mode, and the reason m20-e's own
  // fixture comment chose repeating notes over a held chord in the first
  // place.
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n── ACT 5a: recoverEngine POSITIVE CONTROL (repeating notes) ──");
  {
    let r5 = await cmd("project.new", { discardChanges: true });
    ck("A5a project.new ok", r5.ok, JSON.stringify(r5.error));
    r5 = await cmd("output.setDevice", { uid: UID });
    ck("A5a output pin still held into this act", r5.ok && bhOf(devicesOf(r5)).isSelected === true, JSON.stringify(r5.error));

    r5 = await cmd("track.add", { kind: "instrument", name: "Control5" });
    const ctrlId = (r5.result?.track ?? r5.result)?.id;
    ck("A5a control track added", !!ctrlId, JSON.stringify(r5));
    r5 = await cmd("track.setInstrument", { trackId: ctrlId, soundBank: { source: "gm", program: 0 } });
    ck("A5a control instrument assigned (GM bank)", r5.ok, JSON.stringify(r5.error));
    await sleep(SETTLE_AFTER_INSTRUMENT_MS);

    const CTRL_STEP = 0.1, CTRL_NOTE_LEN = 0.08, CTRL_LEN_BEATS = 80;
    const ctrlNotes = [];
    for (let i = 0; i < CTRL_LEN_BEATS / CTRL_STEP; i++) {
      ctrlNotes.push({ pitch: 60, velocity: 100, startBeat: +(i * CTRL_STEP).toFixed(2), lengthBeats: CTRL_NOTE_LEN });
    }
    r5 = await cmd("clip.addMIDI", { trackId: ctrlId, atBeat: 0, lengthBeats: CTRL_LEN_BEATS, name: "Pulse5", notes: ctrlNotes });
    ck("A5a control clip added with every note accepted", r5.ok && r5.result?.notes?.length === ctrlNotes.length,
       JSON.stringify(r5.error ?? { got: r5.result?.notes?.length, want: ctrlNotes.length }));

    r5 = await cmd("transport.seek", { beats: 0 });
    ck("A5a transport.seek(0) ok", r5.ok, JSON.stringify(r5.error));
    r5 = await cmd("transport.play");
    ck("A5a transport.play ok", r5.ok, JSON.stringify(r5.error));
    await sleep(SETTLE_AFTER_PLAY_MS);

    let h5 = await monitor("A5a pre-trigger baseline", PRE_TRIGGER_WINDOW_MS);
    ck("A5a pre-trigger: control audible", h5.maxDB > AUDIBLE_DB, `max ${h5.maxDB.toFixed(1)} dB`);
    ck("A5a pre-trigger: render callbacks flowing", h5.callbackGrowth && h5.perfReads > 0,
       `growth=${h5.callbackGrowth} reads=${h5.perfReads}`);

    // ── THE TRIGGER — flip BlackHole's nominal rate while rolling ──────────
    console.log(`  [A5a] flip -> ${STAGED_DEVICE_RATE}:`, bhrate(String(STAGED_DEVICE_RATE)));
    const flipped5a = readBackOf(bhrate()); // re-read rather than trust the flip call's own printed value
    ck("A5a TRIGGER: device rate actually moved (read-back verified)", flipped5a === STAGED_DEVICE_RATE, `${flipped5a}`);

    // Standing constraint, checked right after the trigger, per m20-j: a
    // config-change recovery re-establishes output — if the pin were lost
    // here the control note (and ACT 5b's organ note) would reach the user's
    // real speakers, not the loopback.
    r5 = await cmd("output.listDevices");
    ck("A5a output pin STILL held immediately after the flip (m20-j safety property)",
       bhOf(devicesOf(r5)).isSelected === true, JSON.stringify(bhOf(devicesOf(r5))));

    h5 = await monitor("A5a post-trigger (control must recover)", ACT2_POST_TRIGGER_WINDOW_MS, { intervalMs: 5 });
    ck("A5a ⚠️ ANTI-VACUITY — control stays audible by the LATE window across a REAL engine "
       + "bounce (if this is red, the flip/converter itself is dropping audio and ACT 5b's "
       + "result cannot be attributed to the note-chase mechanism)",
       h5.lateMax > AUDIBLE_DB,
       `late[t>=${LATE_WINDOW_MS}] max ${Number.isFinite(h5.lateMax) ? h5.lateMax.toFixed(1) : "n/a"} dB`);
    ck("A5a post-trigger: render callbacks kept flowing", h5.callbackGrowth, `reads=${h5.perfReads}`);

    r5 = await cmd("transport.stop");
    ck("A5a transport.stop ok", r5.ok, JSON.stringify(r5.error));

    // Restore before 5b so both the control and the defect measure the SAME
    // 48k -> 44.1k transition, never a stale 44.1k baseline carried forward.
    const restored5a = bhrate(String(RESTORE_RATE));
    ck("A5a device rate restored to 48000 before ACT 5b (read-back verified)",
       readBackOf(restored5a) === RESTORE_RATE, restored5a);
  }

  console.log("\n── ACT 5b: recoverEngine THE DEFECT (one 128-beat held note) ──");
  await runHeldNoteAct("A5b", {
    assertFreeze: false, // recoverEngine bounces the engine — freeze is m23-bq's property, not bp's
    trigger: async () => {
      console.log(`  [A5b] flip -> ${STAGED_DEVICE_RATE}:`, bhrate(String(STAGED_DEVICE_RATE)));
      const flipped = readBackOf(bhrate());
      const ok = flipped === STAGED_DEVICE_RATE;
      if (!ok) return { ok, detail: `device rate did not move: read-back ${flipped}` };
      // m20-j safety property, right after the trigger (see ACT 5a).
      const dv = await cmd("output.listDevices");
      const pinHeld = bhOf(devicesOf(dv)).isSelected === true;
      ck("A5b output pin STILL held immediately after the flip (m20-j safety property)",
         pinHeld, JSON.stringify(bhOf(devicesOf(dv))));
      return { ok: ok && pinHeld, detail: `device rate -> ${flipped}, pin held=${pinHeld}` };
    },
  });

  // The ONE written setting for ACT 5, restored and VERIFIED by read-back —
  // the same leg shape as m20-e's L12. A best-effort second attempt also
  // lives in `finally` below in case something above threw first.
  const restored5b = bhrate(String(RESTORE_RATE));
  ck("A5b device rate restored to 48000 (read-back verified)",
     readBackOf(restored5b) === RESTORE_RATE, restored5b);

  // ── L-final: the m20-j safety property — release the pin and PROVE the ──
  // macOS system default was never moved. This must be an asserted leg, not
  // just an inference from "we only ever called output.setDevice with the
  // loopback uid" — a silent failure elsewhere could have changed it.
  r = await cmd("output.setDevice", {});
  ck("L-final pin released", r.ok && devicesOf(r).every(d => !d.isSelected), JSON.stringify(r.error));
  r = await cmd("output.listDevices");
  ck("L-final SYSTEM DEFAULT UNMOVED across the whole gate",
     defaultUID(devicesOf(r)) === systemDefault, `${systemDefault} -> ${defaultUID(devicesOf(r))}`);
} catch (e) {
  fail++;
  console.log("FAIL gate threw :: " + (e?.stack ?? e?.message ?? e));
} finally {
  try {
    if (ws) {
      // Best-effort fallback release — only reached if something above threw
      // before the asserted L-final release did. Nothing here is asserted.
      await cmd("output.setDevice", {}).catch(() => {});
    }
  } catch { /* best effort */ }
  // Best-effort fallback device-rate restore (m23-bp-2, ACT 5) — only
  // reached if something above threw before ACT 5a/5b's own asserted
  // restores did. Nothing here is asserted; it does not need `ws` and is
  // safe to call even if the app never connected. BlackHole-only, per
  // `m20d-bhrate`'s own compile-time UID restriction.
  try { bhrate(String(RESTORE_RATE)); } catch { /* best effort */ }
  try { ws?.close(); } catch {}
  await sleep(500);
  try { stopStaging(GATE); } catch (e) { console.log("stopStaging: " + e?.message); }
  await sleep(600);
}

console.log(`\nORCH_M23BP pass=${pass} fail=${fail} skipped=${skipped}`);
if (skipped) {
  console.log(`⚠️ ${skipped} leg(s) SKIPPED — a precondition failed before the site under test `
    + "could be exercised (see the SKIP lines above). A skip is neither pass nor fail; it must "
    + "be investigated, not read as a pass (m23-bl).");
}
console.log(fail
  ? "⚠️ RED IS NOT EXPECTED — m23-bp is FIXED on this tree. Every leg above is a live "
    + "regression check, not a reproduction; a red leg means the fix (or one of the m23-bp-2 "
    + "per-site legs) has broken, and must be investigated as a real regression, never "
    + "relabelled 'expected'."
  : "ALL GREEN, as expected on a fixed tree. If you are running this against a tree WITHOUT "
    + "m23-bp/m23-bp-1 (RescheduleCause) applied, this all-green result means the gate is not "
    + "reproducing the defect and needs re-diagnosis before it can be trusted either way.");
process.exit(fail ? 1 : 0);
