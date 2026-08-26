// m23-dx-3 — the window pinner, run as its own process by `startStaging`.
//
// WHY A SEPARATE PROCESS. The pin has to land after the defaults-domain reset,
// after the app window exists, and BEFORE any gate code runs — and it has to
// work for all 75 non-harness gates, only 31 of which import the harness
// `connect()` (the other 44 hand-roll a raw WebSocket or define a local
// `connect`). The one call every gate makes is `startStaging`, which is
// SYNCHRONOUS; making it async would break the whole corpus. `spawnSync` on
// this file gives `startStaging` the synchronous semantics it needs while the
// pin itself does async socket work.
//
// ⛔ THIS IS NOT THE "THROWAWAY PINNING SESSION" THAT FAILED AT m23-dx-2. That
// method pinned in one APP SESSION and expected the size to survive into the
// NEXT one, across `startStaging`'s defaults reset — it does not. This process
// is short-lived, but the APP it pins is the very app the gate is about to
// drive: same session, already past the reset. Nothing has to persist.
//
// Usage: node _pin-window.mjs <port> <width> <height>
//
// ⚠️ THE PORT RULE HAS ONE HOME AND THIS IS NOT IT. This file opens a socket, so
// it must assert the rule rather than trust its caller — but by IMPORTING
// `assertStagingPort`, not by restating it. The first draft hard-coded
// `port !== 17695`, which is STRICTER than the real rule (`assertStagingPort`
// forbids only the live port and non-positive integers, so any other staging
// port is legal). That mismatch would have hard-failed a legitimate
// `startStaging({ port })` — and ONLY when STAGING_WINDOW_SIZE was set, so it
// would have stayed invisible until someone ran a sweep. Two spellings of one
// rule is the defect; importing is the fix. `assertStagingPort` logs and
// `process.exit(2)`s itself, which already matches this file's convention.
import { assertStagingPort } from "./_staging.mjs";

const [, , portArg, widthArg, heightArg] = process.argv;
const port = assertStagingPort(portArg);
const width = Number(widthArg), height = Number(heightArg);

if (!(width > 0 && height > 0)) {
  console.error(`_pin-window: bad size ${widthArg}x${heightArg}`);
  process.exit(2);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let ws = null;
for (let i = 0; i < 40 && !ws; i++) {
  try {
    ws = await new Promise((res, rej) => {
      const w = new WebSocket(`ws://127.0.0.1:${port}`);
      w.addEventListener("open", () => res(w));
      w.addEventListener("error", () => rej(new Error("refused")));
    });
  } catch { await sleep(500); }
}
if (!ws) {
  console.error(`_pin-window: could not connect to staging on ${port}`);
  process.exit(1);
}

let n = 0;
function cmd(command, params = {}, timeoutMs = 20000) {
  return new Promise((res, rej) => {
    const id = `_pin_${++n}`;
    const t = setTimeout(() => { ws.removeEventListener("message", h); rej(new Error("TIMEOUT " + command)); }, timeoutMs);
    const h = (ev) => {
      let m; try { m = JSON.parse(ev.data); } catch { return; }
      if (m.id !== id) return;
      clearTimeout(t); ws.removeEventListener("message", h); res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id, command, params }));
  });
}

async function readFrame() {
  for (let i = 0; i < 24; i++) {
    const r = await cmd("debug.windowFrame", {});
    const wf = r && r.result;
    if (wf && typeof wf.width === "number" && typeof wf.height === "number") return wf;
    await sleep(250);   // the window may not exist yet immediately after spawn
  }
  return null;
}

const before = await readFrame();
if (!before) {
  console.error("_pin-window: the staging window never reported a frame — cannot pin, and continuing would run at an unknown size.");
  try { ws.close(); } catch {}
  process.exit(1);
}

// ⚠️ THE NO-OP CASE IS LABELLED, NOT HIDDEN. 1440x900 is the app default, so
// pinning to it sets what is already there; its read-back would "succeed" while
// proving nothing about whether the pin does any work. That is the exact shape
// that blessed the broken method at m23-dx-2. Pinning the default is legitimate,
// so this is not an error — but the two log lines must never be confusable, and
// it is the SWEEP's job to require that two arms' GATE-REPORTED frames differ.
if (before.width === width && before.height === height) {
  console.log(`pin: ${width}x${height} (already — no change; this run proves nothing about the pin)`);
  try { ws.close(); } catch {}
  process.exit(0);
}

await cmd("debug.windowFrame", { width, height });
await sleep(600);
const after = await readFrame();
if (!(after && after.width === width && after.height === height)) {
  // Loud and non-zero: the caller asked for a size, so running at another one is
  // a WRONG MEASUREMENT, not a cosmetic miss. `startStaging` turns this into a throw.
  console.error(
    `_pin-window: ${width}x${height} did NOT take — window reports ` +
    `${after ? `${after.width}x${after.height}` : "unknown"}. ` +
    `A setter's return is not proof it took; this is the read-back.`
  );
  try { ws.close(); } catch {}
  process.exit(1);
}
console.log(`pin: ${before.width}x${before.height} -> ${after.width}x${after.height}`);
try { ws.close(); } catch {}
process.exit(0);
