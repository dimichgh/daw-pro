// m18-g gate — sketchpad row/card honesty during a REAL model-load boot.
// Sidecar must be STOPPED beforehand: debug.sketchpadGenerate drives the
// REAL model.generate() -> awaitsBoot auto-start -> submit-during-model-load
// window. Asserts at every window that the candidate ROW (debug.sketchpadState
// candidates[].row, the m18-g resolved presentation) tells the SAME story as
// the card (debug.generationCard stageLabel) for the same jobId — the filed
// defect was the row showing a stale/wrong status while the card correctly
// narrated "loading model". Captures row+card in ONE frame via
// debug.captureUI (twice per window — settle law; the -b file is settled).
//
// Provenance: filed m17-h (loading-model leg), written as a live gate
// 2026-07-16, promoted into scripts/gates/ 2026-07-16 (m19-h hygiene sweep).
// Verified on this machine 2026-07-16: candidate row text matched the card's
// stageLabel verbatim at every window, never RECONNECTING, never QUEUED
// during the load window.
//
// >>> CONVERTED TO THE _staging.mjs HARNESS (m23-ac-3e-2) <<<
// This gate now BUILDS AND LAUNCHES its own binary on the harness's
// STAGING_PORT (17695), instead of driving whatever instance happened to be
// listening on a port — the m23-ac defect class (unknown provenance: a gate
// in that shape can pass against code minutes or days old and cannot tell you
// that it did). There is no env-var port override left: the old
// `DAW_CONTROL_PORT` line did nothing useful, and an operator setting it to
// 17600 would have pointed a real-model-boot probe at the user's live app
// (the m23-bi defect class, present in 6 gates before this conversion).
// `startStaging`/`connect` refuse 17600 structurally (`assertStagingPort`).
//
// ⚠️ HARD PRECONDITION, UNCHANGED BY THIS CONVERSION AND NOT STRUCTURAL LIKE
// PORT/PROVENANCE NOW ARE: the ACE sidecar must be STOPPED before this gate
// runs. Leg W1 — the gate's core — only exists on a COLD boot: a warm sidecar
// skips straight past `startingSidecar`/`awaitsBoot` and the window this gate
// exists to assert never opens. The window is also SINGLE-USE per sidecar
// lifetime on this machine right now (m23-bb: a stopped sidecar cannot
// currently be re-stopped once started) — do not run this gate speculatively.
//
// Staging port law: this gate targets ONLY the harness's STAGING_PORT
// (17695) — never 17600 (the user's live app port).
// Usage: node scripts/gates/m18g-sketchpad-honesty.mjs [outdir]
//   outdir defaults to /tmp/daw-gate-out/m18g-sketchpad-honesty
import fs from "fs";
import { buildOrAbort, startStaging, stopStaging, connect } from "./_staging.mjs";
const GATE = "m18g-sketchpad-honesty";
const OUT = process.argv[2] || "/tmp/daw-gate-out/m18g-sketchpad-honesty";
fs.mkdirSync(OUT, { recursive: true });
const sleep = ms => new Promise(r => setTimeout(r, ms));
buildOrAbort({ label: "building staging binary (m18g)…" });
startStaging({ gate: GATE });
const ws = await connect();
// Failure-path teardown (m23-bd): the `check()` calls below never throw, but an
// uncaught `cmd()` TIMEOUT (several calls below have no `.catch()`, matching the
// original file's behaviour) or any other unexpected error must still stop
// staging rather than leak it for the next gate to silently drive. `stopStaging`
// is idempotent, so this and the explicit call at the bottom (success path)
// cannot double-fire badly. Mirrors current house style (m23am-refusal-anchor.mjs).
const teardown = () => { try { stopStaging(GATE); } catch {} };
for (const ev of ["uncaughtException", "unhandledRejection"]) {
  process.on(ev, (e) => { console.error(`${ev}:`, e && e.message); teardown(); process.exit(2); });
}
let n = 0, pass = 0, fail = 0;
function cmd(command, params = {}, timeoutMs = 30000) {
  return new Promise((res, rej) => {
    const i = `g_${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), timeoutMs);
    const h = ev => {
      const m = JSON.parse(ev.data);
      if (m.id !== i) return;
      clearTimeout(t); ws.removeEventListener("message", h); res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id: i, command, params }));
  });
}
function check(name, ok, detail = "") {
  if (ok) { pass++; console.log(`PASS ${name}`); }
  else { fail++; console.log(`FAIL ${name} :: ${detail}`); }
}
// NOTE for the next audit (m23-ac-3e-2): this is a FUNCTION DEFINITION, not an
// executed statement — the `check()` inside it runs only when a caller invokes
// `captureTwice`, which happens later, after the fixture is seeded below (W1/W2
// call it from inside the poll loop). A prior pass mis-filed this as "asserts
// before it seeds" by reading this definition's line number as if it were
// execution order; it is not. The first EXECUTED assertion in this file is the
// `project.new` check immediately after the seed call. Leave this ordering as
// it is.
async function captureTwice(tag) {
  await cmd("debug.captureUI", { path: `${OUT}/cap-${tag}-a.png` });
  await sleep(400);
  const r = await cmd("debug.captureUI", { path: `${OUT}/cap-${tag}-b.png` });
  check(`capture ${tag}`, r.ok, JSON.stringify(r.error ?? ""));
}
// The ROW's displayed status text, derived exactly as SketchpadCandidateRow renders
// the resolved candidate (queued -> QUEUED, running -> statusText.uppercased() or
// GENERATING, terminal -> its own labels).
function rowDisplayText(row) {
  if (!row) return null;
  switch (row.state) {
    case "queued": return "QUEUED";
    case "running": return (row.statusText ?? "GENERATING").toUpperCase();
    case "succeeded": return "DONE";          // buttons body; DONE is the story
    case "failed": return "FAILED";
    case "imported": return "IMPORTED";
    default: return row.state;
  }
}

// -- Arrange the stage -------------------------------------------------------
let r = await cmd("project.new", { discardChanges: true });
check("project.new", r.ok, JSON.stringify(r.error ?? ""));
r = await cmd("debug.generationCard");
check("card empty at start", r.ok && r.result.jobs.length === 0, JSON.stringify(r.result ?? {}));
r = await cmd("ai.sidecarStatus");
console.log("sidecar pre-gate:", JSON.stringify(r.result ?? r.error));
r = await cmd("ui.showSketchpad");
await sleep(400);

// -- The REAL boot path: generate with the sidecar stopped --------------------
r = await cmd("debug.sketchpadGenerate", {
  prompt: "m18g honesty probe warm synth pop", durationSeconds: 15 });
check("sketchpadGenerate accepted", r.ok, JSON.stringify(r.error ?? ""));

let sawPresubmitBoot = false, capturedLoading = false, capturedRunning = false, terminal = null;
for (let t = 0; t < 900; t++) {
  await sleep(1000);
  const card = await cmd("debug.generationCard").catch(() => null);
  const pad = await cmd("debug.sketchpadState").catch(() => null);
  const cj = card?.result?.jobs?.find(j => j.origin === "sketchpad");
  const cand = pad?.result?.candidates?.[0];
  const line = {
    t,
    card: cj ? { phase: cj.phase, stageLabel: cj.stageLabel, jobId: cj.jobId ?? null,
                 stale: cj.stale, elapsed: cj.elapsed } : null,
    cand: cand ? { state: cand.state, stale: cand.stale, jobId: cand.jobId,
                   row: cand.row ? { state: cand.row.state, statusText: cand.row.statusText ?? null,
                                     stale: cand.row.stale } : null } : null,
  };
  console.log("TICK " + JSON.stringify(line));

  // W0: pre-submit boot — card narrates, no candidate exists yet (log-only frame).
  if (!sawPresubmitBoot && cj && !cj.jobId && cj.phase === "startingSidecar" && !cand) {
    sawPresubmitBoot = true;
    await cmd("debug.captureUI", { path: `${OUT}/cap-boot-presubmit.png` });
    console.log("captured pre-submit boot frame");
  }

  // W1: THE FILED WINDOW — submitted job, card says the model is loading.
  if (!capturedLoading && cj && cj.jobId && cj.phase === "startingSidecar" && cand && cand.row) {
    check("W1 raw candidate is queued (the old story would have shown QUEUED)",
          cand.state === "queued", JSON.stringify(cand));
    check("W1 row does NOT say QUEUED", rowDisplayText(cand.row) !== "QUEUED", JSON.stringify(cand.row));
    check("W1 row is not RECONNECTING", cand.row.stale === false, JSON.stringify(cand.row));
    check("W1 row text equals card stageLabel",
          rowDisplayText(cand.row) === cj.stageLabel,
          `row=${rowDisplayText(cand.row)} card=${cj.stageLabel}`);
    await captureTwice("loading-model");
    capturedLoading = true;
  }

  // W2: running — both surfaces carry the same (rich, verbatim) stage story.
  if (!capturedRunning && cj && cj.phase === "running" && cand && cand.row && cand.row.state === "running") {
    check("W2 row text equals card stageLabel",
          rowDisplayText(cand.row) === cj.stageLabel,
          `row=${rowDisplayText(cand.row)} card=${cj.stageLabel}`);
    check("W2 row is not RECONNECTING", cand.row.stale === false, JSON.stringify(cand.row));
    await captureTwice("running");
    capturedRunning = true;
  }

  if (cj && (cj.phase === "succeeded" || cj.phase === "failed")) { terminal = cj.phase; }
  if (terminal && cand && cand.state !== "queued" && cand.state !== "running") {
    check("terminal agreement (card " + terminal + " / row " + cand.state + ")",
          (terminal === "succeeded" && cand.state === "succeeded") ||
          (terminal === "failed" && cand.state === "failed"),
          JSON.stringify({ card: cj, cand }));
    await cmd("debug.captureUI", { path: `${OUT}/cap-terminal.png` });
    break;
  }
  if (!cj && !cand && t > 60) { console.log("both surfaces empty — stopping poll"); break; }
}
check("W1 loading-model window was captured (the gate's core)", capturedLoading, "window never seen");
console.log(`windows: presubmit=${sawPresubmitBoot} loading=${capturedLoading} running=${capturedRunning} terminal=${terminal}`);

// -- Normalize ----------------------------------------------------------------
await cmd("debug.sketchpadReset").catch(() => null);
await cmd("debug.generationCard", { clear: true }).catch(() => null);
r = await cmd("project.new", { discardChanges: true });
check("normalize project.new", r.ok, JSON.stringify(r.error ?? ""));
r = await cmd("debug.generationCard");
check("card empty at end", r.ok && r.result.jobs.length === 0, JSON.stringify(r.result ?? {}));
console.log(`M18G_GATE pass=${pass} fail=${fail}`);
stopStaging(GATE);   // SIGTERMs by exact pid AND releases our session.lock
ws.close();
process.exit(fail === 0 ? 0 : 1);
