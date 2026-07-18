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
// Staging port law: DAW_CONTROL_PORT env, default 17695 — NEVER 17600 (the
// user's live app port).
// Usage: DAW_CONTROL_PORT=17695 node scripts/gates/m18g-sketchpad-honesty.mjs [outdir]
//   outdir defaults to /tmp/daw-gate-out/m18g-sketchpad-honesty
import fs from "fs";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.argv[2] || "/tmp/daw-gate-out/m18g-sketchpad-honesty";
fs.mkdirSync(OUT, { recursive: true });
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function connect() {
  for (let i = 0; i < 30; i++) {
    try {
      return await new Promise((res, rej) => {
        const w = new WebSocket(`ws://127.0.0.1:${PORT}`);
        w.addEventListener("open", () => res(w));
        w.addEventListener("error", () => rej(new Error("refused")));
      });
    } catch { await sleep(1000); }
  }
  throw new Error(`no connect to ${PORT}`);
}
const ws = await connect();
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
ws.close();
process.exit(fail === 0 ? 0 : 1);
