// m23-dx-2 helper — pin the ambient staging window size, then exit.
// Usage: PIN_W=1440 PIN_H=900 node scripts/gates/_m23dx2-pin.mjs
//
// The size survives into the next staging session — MEASURED by
// _m23dx2-pin-persistence-probe.mjs (S1 inherited 1440x900, set 1400x1000,
// S2 inherited 1400x1000), which is what makes m23-dx's "throwaway pinning
// session" method work at all. ⚠️ That probe's FIRST version was vacuous: it
// set the size the session already had, so its "survived" answer was true
// either way. Do not re-verify this with a no-op write.
//
// This helper does NOT assert the gate's verdict — it only moves the ambient
// state. Each gate prints its own inherited frame (m23-bg), so the arm's real
// evidence that it ran at the intended size comes from the GATE's log, not
// from this script's word.
import { buildOrAbort, startStaging, stopStaging, connect, sleep } from "./_staging.mjs";

const W = Number(process.env.PIN_W || 0);
const H = Number(process.env.PIN_H || 0);
if (!Number.isFinite(W) || !Number.isFinite(H) || W <= 0 || H <= 0) {
  console.log(`ABORT: PIN_W/PIN_H must be positive numbers; got ${process.env.PIN_W}/${process.env.PIN_H}`);
  process.exit(2);
}

const GATE = "m23dx2-pin";
let n = 0;
buildOrAbort({ label: `pinning staging window to ${W}x${H}…` });
startStaging({ gate: GATE });
const ws = await connect();
const cmd = (command, params = {}, timeoutMs = 30000) =>
  new Promise((res, rej) => {
    const i = `pin_${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), timeoutMs);
    const h = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id !== i) return;
      clearTimeout(t); ws.removeEventListener("message", h); res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id: i, command, params }));
  });

let wf = null;
for (let i = 0; i < 20 && !(wf && typeof wf.width === "number"); i++) {
  wf = (await cmd("debug.windowFrame", {})).result;
  if (!(wf && typeof wf.width === "number")) await sleep(250);
}
console.log(`pin: inherited ${wf ? `${wf.width}x${wf.height}` : "unknown"}`);
await cmd("debug.windowFrame", { width: W, height: H });
await sleep(600);
const back = (await cmd("debug.windowFrame", {})).result;
console.log(`pin: read-back  ${back ? `${back.width}x${back.height}` : "unknown"}`);
try { ws.close(); } catch {}
stopStaging(GATE);

// A setter's return is not proof it took — this asserts the READ-BACK.
const ok = back && back.width === W && back.height === H;
console.log(ok ? `pin: OK ${W}x${H}` : `pin: FAILED to reach ${W}x${H}`);
process.exit(ok ? 0 : 1);
