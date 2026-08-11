// ⛔⛔ THIS PROBE'S ANSWER IS WRONG. IT REPORTS "METHOD IS VALID"; THE REAL
// TWO-ARM RUN THAT FOLLOWED PROVED IT IS NOT. Read this whole block before
// trusting anything below.
//
// The probe pins 1400x1000 in session 1 and finds 1400x1000 in session 2, so it
// concludes the size survives `startStaging`'s defaults-domain reset. But when
// the same pin was done by a SEPARATE process and followed by a real gate run
// (m23-dx-2 arms A and B), BOTH m17h and m18g reported inheriting 1440x900 —
// the app default — even though the pin's own read-back said 1400x1000. All
// four runs across both arms ran at 1440x900.
//
// So the persistence is RACY, not reliable: it held across two sessions 1.5 s
// apart inside ONE node process, and did NOT hold across a process boundary.
// That is worse than simply broken, because a probe like this one will
// intermittently say it works.
//
// ⭐ THE LESSON THIS FILE EXISTS TO CARRY: a probe that reproduces the
// mechanism in MINIATURE is not the same instrument as the real thing. This one
// differed from the actual use in exactly the way that mattered (same process,
// shorter gap) and returned the comfortable answer. The real arms were only
// caught because m17h and m18g each PRINT the frame they inherited — the
// experiment was self-verifying, and the probe was not.
//
// m23-dx-2 PREMISE PROBE — does an ambient window size set in one staging
// session SURVIVE into the next?
//
// m23-dx's METHOD (inherited by dx-2) is: "set the ambient size with a
// throwaway pinning session, run the gate, compare the verdict at two sizes".
// That method REQUIRES the size to persist across `startStaging` calls. But
// `_staging.mjs` CLEARS the staging defaults domain on every start and reseeds
// exactly one key, and the seed file says in terms: "NEVER add an NS* key
// (NSWindow Frame …) — those must be left to regenerate in the staging domain".
// An NSWindow frame autosave lives in that same domain, so the reset should
// destroy it.
//
// This probe answers it by MEASUREMENT, not by reading the reset code:
//   session 1: set 1440x900, read back (proves the setter took)
//   session 2: read with no set   (proves whether it survived)
//
// `_` prefix keeps this out of the corpus glob and out of m23fa3's scan.
import { buildOrAbort, startStaging, stopStaging, connect, sleep } from "./_staging.mjs";

const GATE = "m23dx2-pin-probe";
let n = 0;
function mkCmd(ws) {
  return (command, params = {}, timeoutMs = 30000) =>
    new Promise((res, rej) => {
      const i = `p_${++n}`;
      const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), timeoutMs);
      const h = (ev) => {
        const m = JSON.parse(ev.data);
        if (m.id !== i) return;
        clearTimeout(t); ws.removeEventListener("message", h); res(m);
      };
      ws.addEventListener("message", h);
      ws.send(JSON.stringify({ id: i, command, params }));
    });
}

// Poll: connect() can return before the window exists.
async function readFrame(cmd) {
  let wf = null;
  for (let i = 0; i < 20 && !(wf && typeof wf.width === "number"); i++) {
    wf = (await cmd("debug.windowFrame", {})).result;
    if (!(wf && typeof wf.width === "number")) await sleep(250);
  }
  return wf;
}

// ⚠️⚠️ THE FIRST VERSION OF THIS PROBE WAS VACUOUS AND SAID "METHOD IS VALID".
// It set 1440x900 — which is exactly what session 1 had ALREADY inherited, so
// the write was a no-op and session 2 would read 1440x900 whether persistence
// worked or not. A probe whose "pass" is indistinguishable from its "fail"
// measures nothing. The target is now a size the session does NOT already have,
// and the probe ABORTS rather than reporting on a no-op write.
const TARGET = { width: 1400, height: 1000 };

buildOrAbort({ label: "building staging binary (dx2 pin probe)…" });

// ---------------------------------------------------------------- session 1
startStaging({ gate: GATE });
let ws = await connect();
let cmd = mkCmd(ws);
const before = await readFrame(cmd);
console.log(`S1 inherited : ${JSON.stringify(before)}`);
if (before && before.width === TARGET.width && before.height === TARGET.height) {
  console.log(`ABORT: inherited size ALREADY equals the target ${TARGET.width}x${TARGET.height} — `
    + "this run could not distinguish persistence from a no-op. Pick a different target.");
  try { ws.close(); } catch {}
  stopStaging(GATE);
  process.exit(2);
}
const setRes = await cmd("debug.windowFrame", TARGET);
console.log(`S1 set(${TARGET.width}x${TARGET.height}) -> ok=${setRes.ok} ${JSON.stringify(setRes.result ?? setRes.error)}`);
await sleep(600);
const afterSet = await readFrame(cmd);
console.log(`S1 read-back : ${JSON.stringify(afterSet)}`);
try { ws.close(); } catch {}
stopStaging(GATE);

await sleep(1500);

// ---------------------------------------------------------------- session 2
startStaging({ gate: GATE });
ws = await connect();
cmd = mkCmd(ws);
const nextSession = await readFrame(cmd);
console.log(`S2 inherited : ${JSON.stringify(nextSession)}`);
try { ws.close(); } catch {}
stopStaging(GATE);

// ------------------------------------------------------------------ verdict
const tookInS1 = afterSet && afterSet.width === TARGET.width && afterSet.height === TARGET.height;
const survived = nextSession && nextSession.width === TARGET.width && nextSession.height === TARGET.height;
console.log("");
console.log(`SETTER TOOK IN SESSION 1 : ${tookInS1}   (a setter's return is not proof it took — this is the read-back)`);
console.log(`SIZE SURVIVED TO SESSION 2: ${survived}`);
console.log(survived
  ? "=> m23-dx's throwaway-pinning METHOD IS VALID under the current harness."
  : "=> m23-dx's throwaway-pinning METHOD IS INVALID under the current harness: the defaults-domain reset in _staging.mjs wipes the NSWindow frame autosave between sessions, so every gate run starts at the app default size regardless of any pinning session.");
