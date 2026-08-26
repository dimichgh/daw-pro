// m16-a C1 regression gate — the deterministic MainActor poisoner recipe.
// (docs/research/design-m16a-canvas-crash.md §1/§6-C1; audit-m16 crash-3 shape.)
//
// Recipe, per iteration: project.new → instrument track + audio track →
// clip.addAudio (a REAL file) → clip.setFades + clip.setGainEnvelope →
// DELETE the file from disk → transport.seek {beats:1} → transport.play →
// wait → transport.stop → project.snapshot liveness probe + notice-honesty
// assertions.
//
// Pre-fix (design round, 6/6): `-[AVAudioPlayerNode playAtTime:]` raises
// "player started when in a disconnected state" on the 2nd play-bearing
// cycle; the NSException unwinds through the MainActor job, leaks the
// executor-tracking TLS record, and the app either crashes at the next
// SE-0423 dynamic-isolation check or wedges (wire connects, every command
// times out). Post-fix (Leg 0 play-guard + Leg 1 ObjC exception barrier):
// every iteration completes and the wire keeps answering.
//
// EXPECTATION REPLACEMENT (2026-07-13, m16-h —
// docs/research/design-m16h-reconfig.md §5.5): this gate originally
// REQUIRED a `clip-unplayable` notice per run ("proof the guard fired").
// That requirement asserted the DEFECT's signature: the raise this recipe
// provoked on iterations ≥2 was the deep post-start reconfig defect (every
// strip born on the running just-rebuilt engine was a dead player host),
// not the missing-media shape. m16-h removed the raise class by
// construction (deferred rebuild start + announce-class strip birth), and
// the dying clip now PLAYS its already-open unlinked fd audibly — so
// `clip-unplayable` is PERMITTED but NOT REQUIRED. The gate's real job —
// wedge/crash detection under the poisoner recipe — is unchanged: all
// iterations must complete, the wire must keep answering, and the
// operator's .ips ledger must be byte-identical around the run.
//
// Staging: this gate BUILDS AND LAUNCHES its own app on 17695 — just run
//   ITERS=10 node scripts/gates/m16a-poison-recipe.mjs
// ITERS and PLAY_MS remain tuning knobs. The PORT knob is GONE (m23-bi):
// it defaulted to 17663 but honoured `process.env.PORT`, one of the most
// commonly-exported names in any shell, so `PORT=17600` pointed this soak —
// 10 iterations of `project.new`, play, and file deletion — at the user's LIVE
// session. `assertStagingPort` now refuses 17600 structurally.
//
// Exit codes (m23-fa-5: now the SHARED scheme from `_verdict.mjs` — 0 passed /
// 1 failed / 2 asserted nothing). The old bespoke scheme (2 dead / 3 wedged /
// 4 shortfall / 5 nothing-ran) is GONE; the dead-vs-wedged-vs-shortfall
// distinction this gate exists to draw now lives where it was always actually
// read — the log line immediately above the verdict ("app dead" / "WEDGED" /
// "iteration shortfall"). See the migration note above the final verdict call
// for why collapsing those three codes loses nothing and fixes something.
// >>> THESE CODES ARE SIGNALS, NOT PASS/FAIL — see the connect budget below. <<<
import fs from "fs";
import os from "os";
import path from "path";
import { buildOrAbort, startStaging, stopStaging, connect } from "./_staging.mjs";
import { verdict } from "./_verdict.mjs";

const GATE = "m16a";                        // names the pidfile + staging out dir
const ITERS = Number(process.env.ITERS || "10");
const PLAY_MS = Number(process.env.PLAY_MS || "6000");
let seq = 0;

// A tiny stereo Float32 WAV fixture, generated fresh so the gate has no
// repo-file dependencies: 1 s of low-amplitude DC at 48 kHz.
function makeWav(at) {
  const frames = 48_000, channels = 2, rate = 48_000;
  const dataBytes = frames * channels * 4;
  const buf = Buffer.alloc(44 + dataBytes);
  buf.write("RIFF", 0); buf.writeUInt32LE(36 + dataBytes, 4); buf.write("WAVE", 8);
  buf.write("fmt ", 12); buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(3, 20); // IEEE float
  buf.writeUInt16LE(channels, 22); buf.writeUInt32LE(rate, 24);
  buf.writeUInt32LE(rate * channels * 4, 28); buf.writeUInt16LE(channels * 4, 32);
  buf.writeUInt16LE(32, 34);
  buf.write("data", 36); buf.writeUInt32LE(dataBytes, 40);
  for (let i = 0; i < frames * channels; i++) buf.writeFloatLE(0.05, 44 + i * 4);
  fs.writeFileSync(at, buf);
}

// CONNECT BUDGET — deliberately NOT the harness default here.
//
// This gate uses connect FAILURE as a verdict: a refused connection means "app
// dead" (exit 2), and the wedge probe distinguishes exit 3 from exit 2 the same
// way. Retry count is therefore NOT a neutral robustness knob — the harness
// default of 40x1 s would turn a genuine crash into a 40-second stall before
// reporting the very same code, and would do it twice on the wedge path. The
// old local connect() was a single attempt with a 5 s timeout; 5x1 s preserves
// that detection latency. The COLD BOOT we now own gets the full budget instead,
// once, before the loop starts.
const reconnect = () => connect({ attempts: 5 });

function cmd(ws, command, params, timeoutMs = 15000) {
  return new Promise((res, rej) => {
    const id = "m16a-c1-" + (++seq);
    const t = setTimeout(() => rej(new Error(`TIMEOUT ${command}`)), timeoutMs);
    const h = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id !== id) return;
      ws.removeEventListener("message", h);
      clearTimeout(t);
      if (!m.ok) rej(new Error(`${command}: ${m.error}`));
      else res(m.result);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id, command, params }));
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (s) => console.log(`[${new Date().toISOString()}] ${s}`);

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "m16a-c1-"));
const NOTICE_FAMILY = ["clip-unplayable", "clip-fades-skipped", "clip-envelope-skipped"];
let sawUnplayable = 0;

async function iteration(ws, iter) {
  await cmd(ws, "project.new");
  await cmd(ws, "track.add", { name: "Keys", kind: "instrument" });
  const t2 = await cmd(ws, "track.add", { name: "Gtr" });
  const dying = path.join(scratch, `dying-${iter}-${Date.now()}.wav`);
  makeWav(dying);
  const clip = await cmd(ws, "clip.addAudio", { trackId: t2.id, path: dying, atBeat: 0 });
  await cmd(ws, "clip.setFades", { trackId: t2.id, clipId: clip.id, fadeInBeats: 0.5, fadeOutBeats: 0.5 });
  await cmd(ws, "clip.setGainEnvelope", { trackId: t2.id, clipId: clip.id,
    points: [{ beat: 0, gainDb: -6 }, { beat: 2, gainDb: 0 }, { beat: 4, gainDb: -12 }] });
  fs.unlinkSync(dying);
  await cmd(ws, "transport.seek", { beats: 1 });
  await cmd(ws, "transport.play");
  await sleep(PLAY_MS);
  await cmd(ws, "transport.stop");

  // Liveness probe + notice honesty (C1 assertions).
  const snap = await cmd(ws, "project.snapshot", undefined, 10000);
  const notices = snap.engineNotices || [];
  const codes = notices.map((n) => n.code);
  if (codes.includes("clip-unplayable")) sawUnplayable++;
  // Post-m16-h a notice-free iteration is the NORM (the dying clip plays
  // its unlinked fd) — informational only, never a failure.
  const familyHit = codes.filter((c) => NOTICE_FAMILY.includes(c));
  if (familyHit.length === 0) {
    log(`iter ${iter}: no guard-family notice (codes: ${codes.join(",") || "none"}) — expected post-m16-h`);
  }
  return codes;
}

buildOrAbort({ label: "building staging binary (m16a)…" });
startStaging({ gate: GATE });
// One full-budget wait for the cold boot, then hand off to the loop's tight
// 5 s reconnects. Without this the FIRST iteration would have to absorb boot
// latency inside a budget sized for crash detection, and a slow launch would
// read as "app dead".
try {
  const boot = await connect();
  try { boot.close(); } catch { /* ignore */ }
} catch {
  log("staging app never accepted a connection — aborting before iteration 1");
  // m23-fa-5: ZERO iterations ran, so this run proves nothing about the
  // poisoner recipe. It is NOT the same event as "the app died at iteration 7"
  // below, which is this gate CATCHING its defect — yet before the migration
  // both exited 2 and were indistinguishable from the outside.
  verdict({ ran: 0, failed: 0 });
}

let clean = 0;
for (let iter = 1; iter <= ITERS; iter++) {
  let ws;
  try {
    ws = await reconnect();
  } catch {
    log(`iter ${iter}: CONNECT FAILED — app dead (pre-fix signature: crash)`);
    // `iter` is 1-based, so ran >= 1 here and verdict's `failed > ran` throw
    // cannot fire: iterations 1..iter-1 completed clean, and THIS one failed.
    verdict({ ran: iter, failed: 1 });
  }
  try {
    const codes = await iteration(ws, iter);
    clean++;
    log(`iter ${iter}: ok — notices [${codes.join(",") || "none"}]`);
  } catch (e) {
    if (String(e.message).startsWith("TIMEOUT")) {
      // Distinguish wedge from crash: try one fresh-connection probe.
      try { ws.close(); } catch {}
      try {
        const probe = await reconnect();
        await cmd(probe, "project.snapshot", undefined, 10000);
        probe.close();
        log(`iter ${iter}: transient timeout but wire answers — continuing (${e.message})`);
      } catch {
        log(`iter ${iter}: WEDGED — wire connects/dead or gone (pre-fix signature: leaked executor record)`);
        verdict({ ran: iter, failed: 1 });
      }
    } else {
      log(`iter ${iter}: command error: ${e.message}`);
      verdict({ ran: iter, failed: 1 });
    }
  }
  try { ws.close(); } catch {}
  await sleep(500);
}

log(`done: ${clean}/${ITERS} iterations clean; clip-unplayable seen in ${sawUnplayable} snapshots (permitted, not required — m16-h)`);
// Both remaining exits are "the soak ran to completion and rendered a verdict",
// so tear the app down here rather than duplicating it in each branch. The
// ABRUPT exits above (2 = dead, 3 = wedged) are covered structurally by
// armTeardown, which is the case that matters most: those fire precisely when
// the app is misbehaving and most likely to be left behind.
stopStaging(GATE);
// m23-fj: `clean === ITERS` is TRUE at ITERS=0 (0 === 0), so this printed "C1 PASS"
// and exited 0 after running ZERO iterations. MEASURED LIVE 2026-08-10, not inferred:
// `ITERS=0 node scripts/gates/m16a-poison-recipe.mjs` -> exit 0, "done: 0/0 iterations
// clean", "C1 PASS". ITERS is a documented tuning knob, so this was a false green one
// env var away, with no code defect required.
//
// ⛔ THE PARAGRAPH BELOW IS THE SUPERSEDED m23-fm DECISION. It is kept verbatim
// because its REASONING WAS MEASURABLY WRONG, and the way it was wrong is the
// finding (m23-fa-5, 2026-08-10):
//
//   > ⚠️ DELIBERATELY NOT MIGRATED TO `_verdict.mjs`, AND THE REASON IS A FINDING (m23-fm):
//   > the primitive exits 2 for "asserted nothing", but THIS GATE ALREADY USES 2 FOR "app
//   > dead" (and 3 for "wedged"). Routing through it would make exit 2 ambiguous WITHIN ONE
//   > GATE — a reader could not tell a dead app from an empty run. So the guard is inline
//   > and uses code 5, which is free in this gate's scheme (0 pass / 2 dead / 3 wedged /
//   > 4 verdict-fail / 5 nothing-ran).
//
// ⭐⭐ "Would MAKE exit 2 ambiguous" presumes exit 2 was UNambiguous. It was not.
// Exit 2 already meant THREE different things in this one file:
//   • the pre-loop abort — "never accepted a connection, aborting before iteration 1",
//     i.e. the soak ran ZERO iterations and proved NOTHING;
//   • the in-loop "CONNECT FAILED — app dead", i.e. the gate CAUGHT THE CRASH it exists
//     to catch — the strongest possible RED;
//   • the in-loop "command error".
// So exit 2 conflated "this gate proved nothing" with "this gate proved the defect is
// back" — the two most opposite verdicts a gate can render, wearing one code. The
// migration did not introduce that ambiguity; it REMOVED it (0 / 1 / 2 now mean passed /
// failed / asserted-nothing, and the first bullet is the only one that keeps code 2).
//
// ⭐ THE GENERAL TRAP, which is why this is worth ten lines: m23-fm reasoned about the
// collision from the PRIMITIVE's side (what does verdict's 2 mean?) and never enumerated
// THIS FILE's own uses of 2. An exit-code audit that reads one end of the mapping is half
// an audit — and the half it skipped was the one already broken.
//
// What the collapse costs: exit codes 3 (wedged) and 4 (shortfall) are gone, so dead vs
// wedged vs shortfall is no longer readable from `$?`. That distinction is preserved in
// the log line printed immediately before each verdict, which is where it was actually
// read — MEASURED: nothing consumes this gate's exit codes (`gate-corpus-run.mjs` scores
// `green = status === 0`, and every other reference to m16a is prose in docs/research/).
//
// The bespoke `ITERS < 1` / exit-5 guard is likewise gone, subsumed rather than deleted:
// `ran: ITERS` sends ITERS=0 straight into verdict's own `ran === 0` branch, which prints
// the shared ASSERTED-NOTHING banner and exits 2. That is the m23-fj false-green fix
// surviving the migration on the one home's machinery instead of its own.
// ⚠️ The PASS/FAIL line MUST stay inside the `else`. `clean === ITERS` is true at
// ITERS=0 (0 === 0) — the exact m23-fj false green — so an unguarded ternary would
// print "C1 PASS" one line above an ASSERTED-NOTHING exit 2. Routing the EXIT through
// verdict() does not sanitise the gate's own LOG; a human reading stdout would still
// see the word PASS on a run that proved nothing.
if (ITERS < 1) {
  log(`ITERS=${ITERS} ran zero iterations. Re-run with ITERS>=1 (default 10).`);
} else {
  log(clean === ITERS ? "C1 PASS" : "C1 FAIL");
}
verdict({ ran: ITERS, failed: ITERS - clean });
