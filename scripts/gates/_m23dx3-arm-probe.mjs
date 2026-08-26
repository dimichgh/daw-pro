// m23-dx-3 ACCEPTANCE PROBE — plays the GATE's role, never the pinner's.
//
// ⭐ WHY THIS SHAPE, AND WHY IT IS NOT THE PROBE THAT LIED AT m23-dx-2.
// The dx-2 probe verified the pin BY READING BACK ITS OWN WRITE, in the same
// process that did the writing, and returned the comfortable answer. The real
// two-arm run then showed every gate still inheriting the app default 1440x900.
//
// This probe therefore does the OPPOSITE of pinning: it sets nothing. It calls
// `startStaging` + `connect()` — the exact two calls every gate opens with —
// and prints the frame it finds AFTERWARDS. Whether a pin happened is decided
// entirely by whether STAGING_WINDOW_SIZE is set in this process's environment,
// which is the ARM. So the number printed here is an INHERITED frame in the same
// sense m17h's and m18g's `m23-bg inherited` lines are, and comparing two arms'
// prints is the negative control the dx-3 item demands:
//
//     "assert the gate's OWN reported inherited frame differs between arms,
//      never the pin's read-back."
//
// ⚠️ RUN THE ARMS AS SEPARATE PROCESS INVOCATIONS, never as two passes inside
// one node process. The dx-2 failure was invisible precisely because the
// miniature stayed inside one process; a same-process pair here would reproduce
// that blind spot even though the current fix no longer depends on persistence.
//
// `_` prefix keeps this out of the corpus glob and out of m23fa3's scan.
import { buildOrAbort, startStaging, stopStaging, connect, sleep } from "./_staging.mjs";

const GATE = "m23dx3-arm-probe";
const ARM = process.env.STAGING_WINDOW_SIZE ? `PINNED(${process.env.STAGING_WINDOW_SIZE})` : "UNPINNED";

let n = 0;
function mkCmd(ws) {
  return (command, params = {}, timeoutMs = 30000) =>
    new Promise((res, rej) => {
      const i = `q_${++n}`;
      const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), timeoutMs);
      const h = (ev) => {
        let m; try { m = JSON.parse(ev.data); } catch { return; }
        if (m.id !== i) return;
        clearTimeout(t); ws.removeEventListener("message", h); res(m);
      };
      ws.addEventListener("message", h);
      ws.send(JSON.stringify({ id: i, command, params }));
    });
}

async function readFrame(cmd) {
  let wf = null;
  for (let i = 0; i < 20 && !(wf && typeof wf.width === "number"); i++) {
    wf = (await cmd("debug.windowFrame", {})).result;
    if (!(wf && typeof wf.width === "number")) await sleep(250);
  }
  return wf;
}

buildOrAbort({ label: "building staging binary (dx3 arm probe)…" });

startStaging({ gate: GATE });
const ws = await connect();          // <- the pin, if any, happens INSIDE here
const cmd = mkCmd(ws);

// This read is INDEPENDENT of anything connect() did. It is the gate's view.
const wf = await readFrame(cmd);
console.log(`ARM=${ARM} gate-reported inherited frame: ${JSON.stringify(wf)}`);
console.log(`ARM=${ARM} SIZE=${wf ? `${wf.width}x${wf.height}` : "unknown"}`);

// Prove the session is actually usable at this size — a pin that wedges the app
// would otherwise look like a success in the frame print alone.
const ov = await cmd("project.overview");
console.log(`ARM=${ARM} project.overview ok=${ov.ok}`);

try { ws.close(); } catch {}
stopStaging(GATE);
