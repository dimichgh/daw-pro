// m17-h orchestrator gate — generation presence card seam matrix (bare-read law, import-origin seed, failed
// reason verbatim, snapshot carries ZERO card keys, bad-phase teaching error, clear verb, dead-sidecar wire
// generate -> boot narration). NOTES: capture verb is debug.captureUI; card elapsed echoes as a formatted
// STRING ("0:33"); the G leg kicks a REAL sidecar boot — kill scripts/ace-step/.ace-step.pid after to restore.
// Staging: DAW_CONTROL_PORT=17695. Promoted from session scratchpad 2026-07-16 (m17-g).
// m17-h orchestrator disjoint gate: seam matrix + wire-dead-sidecar boot narration.
// NOTE: capture/output paths point at /tmp/daw-gate-out — `mkdir -p /tmp/daw-gate-out` before running.
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function connect() {
  for (let i = 0; i < 20; i++) {
    try {
      return await new Promise((res, rej) => {
        const w = new WebSocket("ws://127.0.0.1:17695");
        w.addEventListener("open", () => res(w));
        w.addEventListener("error", () => rej(new Error("refused")));
      });
    } catch { await sleep(1000); }
  }
  throw new Error("no connect");
}
const ws = await connect();
let n = 0, pass = 0, fail = 0;
function cmd(command, params = {}, timeoutMs = 30000) {
  return new Promise((res, rej) => {
    const i = `oh_${++n}`;
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

await cmd("project.new");

// A: bare read law — read-only, empty on fresh app
let r = await cmd("debug.generationCard");
check("A bare read ok + invisible + empty", r.ok && r.result.visible === false && r.result.jobs.length === 0, JSON.stringify(r));

// B: seed IMPORT-origin running row (origin never live-gated by the agent)
r = await cmd("debug.generationCard", { seed: { phase: "running", origin: "import", label: "orch import probe", progress: 0.42, stage: "Generating music (batch size: 2)...", elapsedSeconds: 33 } });
check("B seed import running accepted", r.ok, JSON.stringify(r.error ?? ""));
await sleep(400);
r = await cmd("debug.generationCard");
const bj = r.result?.jobs?.find(j => j.origin === "import");
check("B card visible with import row", r.ok && r.result.visible === true && !!bj, JSON.stringify(r.result ?? {}));
check("B import row echoes progress/stage/elapsed", !!bj && Math.abs(bj.progress - 0.42) < 0.001 && /batch size/.test(bj.stage ?? "") && bj.elapsed >= 33, JSON.stringify(bj ?? {}));
r = await cmd("app.captureUI", { path: "/tmp/daw-gate-out/m17h-orch/cap-import-running.png" });
check("B capture import card", r.ok, JSON.stringify(r.error ?? ""));

// C: seed failed row with verbatim reason; then clear
r = await cmd("debug.generationCard", { seed: { phase: "failed", origin: "wire", label: "orch fail probe", reason: "orchestrator synthetic reason — verbatim echo test", elapsedSeconds: 7 } });
check("C seed failed accepted", r.ok, JSON.stringify(r.error ?? ""));
await sleep(400);
r = await cmd("debug.generationCard");
const cj = r.result?.jobs?.find(j => j.phase === "failed");
check("C failed row verbatim reason", !!cj && cj.reason === "orchestrator synthetic reason — verbatim echo test", JSON.stringify(cj ?? {}));

// D: snapshot cleanliness — card state is app-level, never project data
r = await cmd("project.snapshot");
const snapStr = JSON.stringify(r.result ?? {});
check("D no generation-card keys in project snapshot", r.ok && !/generationCard|presenceJob|GenerationPresence/i.test(snapStr), snapStr.slice(0, 200));

// E: teaching error on bad phase
r = await cmd("debug.generationCard", { seed: { phase: "wiggling" } });
check("E bad phase refused with teaching error", !r.ok && typeof r.error === "string" && /phase/.test(r.error), JSON.stringify(r.error ?? "no error"));

// F: clear verb empties the card
r = await cmd("debug.generationCard", { clear: true });
await sleep(300);
r = await cmd("debug.generationCard");
check("F clear empties card", r.ok && r.result.visible === false && r.result.jobs.length === 0, JSON.stringify(r.result ?? {}));

// G: wire generate with sidecar STOPPED — error verbatim mentions the sidecar, card narrates the boot
r = await cmd("ai.sidecarStatus");
console.log("sidecar status pre-G:", JSON.stringify(r.result ?? r.error));
r = await cmd("ai.generateSong", { prompt: "orch boot narration probe", durationSeconds: 15 }, 20000).catch(e => ({ ok: false, error: String(e) }));
check("G wire generate errors while sidecar down", !r.ok && typeof r.error === "string" && /sidecar|start/i.test(r.error), JSON.stringify(r.error ?? ""));
await sleep(800);
r = await cmd("debug.generationCard");
const gj = r.result?.jobs?.find(j => j.phase === "startingSidecar" || /start/i.test(j.stageLabel ?? ""));
check("G card narrates the kicked boot", r.ok && r.result.visible === true && !!gj, JSON.stringify(r.result ?? {}));
console.log("G boot row:", JSON.stringify(gj ?? {}));

// normalize + report
await cmd("debug.generationCard", { clear: true });
await cmd("project.new");
console.log(`ORCH_M17H_GATE pass=${pass} fail=${fail}`);
ws.close();
process.exit(0);
