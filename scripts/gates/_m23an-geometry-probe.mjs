// _m23an-geometry-probe.mjs — A MEASUREMENT INSTRUMENT, NOT A GATE.
// `_`-prefixed so the gate corpus counter correctly skips it as harness.
//
// ONE QUESTION, asked of pixels because no seam can answer it: WHERE does the
// m23-an acknowledgement chip actually get drawn, relative to the row it names?
//
// The seam leg (D3b) proves `trackClickAckTrackId` is the clicked track. That is
// attribution IN THE MODEL. m23-am was the cycle that paid for the difference:
// the model named the right object and the pixels put the word on an innocent
// one. So this probe captures the frame and I LOOK at it.
//
// Two cases, because they fail differently:
//   G-MID   ack on a MIDDLE empty row  — does the chip's body land on the NEXT
//           row's band? (offset y = tops[i] + heights[i] + 2, VStack spacing 6,
//           chip ~21 pt tall => arithmetic says it covers ~17 pt of row i+1.)
//   G-LAST  ack on the LAST row        — tops[last] + heights[last] is the row
//           stack's own bottom edge, so the chip is drawn OUTSIDE the stack. Is
//           it clipped away entirely? A newly added track lands last and has no
//           clips, which is the single likeliest way a user meets this feature.
//
// Staging port 17695 ONLY (17600 is the user's LIVE app). PIDFILE-EXACT kill.
//
//   node scripts/gates/_m23an-geometry-probe.mjs
import fs from "fs";
import { execFileSync } from "child_process";
import { buildOrAbort, startStaging, stopStaging } from "./_staging.mjs";

const GATE = "m23angeo";
const PORT = "17695";
const OUT = "/tmp/m23an-geo";
const PIDFILE = "/tmp/m23angeo-staging.pid";
const BINARY = ".build/debug/DAWApp";
const REPO = process.cwd();
fs.mkdirSync(OUT, { recursive: true });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 600_000);

buildOrAbort({ root: REPO });

async function connect() {
  for (let i = 0; i < 60; i++) {
    try {
      const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
      await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error("x")); });
      let nextId = 1; const pending = new Map();
      ws.onmessage = (ev) => {
        let m; try { m = JSON.parse(ev.data); } catch { return; }
        const e = pending.get(m.id); if (!e) return; pending.delete(m.id);
        if (m.ok === false || m.error) e.reject(new Error(`${e.command}: ${JSON.stringify(m.error)}`));
        else e.resolve(m.result ?? m);
      };
      const req = (command, params = {}) => {
        const id = String(nextId++);
        return new Promise((resolve, reject) => {
          pending.set(id, { resolve, reject, command });
          ws.send(JSON.stringify({ id, command, params }));
          setTimeout(() => {
            if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${command}`)); }
          }, 25000);
        });
      };
      return { ws, req };
    } catch { await sleep(500); }
  }
  throw new Error("no connect");
}

const staging = startStaging({
  gate: GATE, root: REPO, port: PORT, binary: BINARY,
  detached: true, pidfile: PIDFILE, outDir: OUT,
});
console.log(`staging pid ${staging.pid} on :${PORT}`);
await sleep(4500);
const { ws, req } = await connect();
const teardown = () => { try { stopStaging(GATE, PIDFILE); } catch {} };
for (const ev of ["uncaughtException", "unhandledRejection"]) {
  process.on(ev, (e) => { console.error(`${ev}:`, e && e.message); teardown(); process.exit(2); });
}

let capSeq = 0;
const shaOf = (p) => execFileSync("/usr/bin/shasum", ["-a", "256", p]).toString().split(" ")[0];
async function capture(tag) {
  const path = `${OUT}/${tag}-${capSeq++}.png`;
  const r = await req("debug.captureUI", { path });
  return { path, width: r.width, height: r.height, sha: shaOf(path) };
}
async function stableCapture(tag) {
  let prev = await capture(tag);
  for (let i = 0; i < 12; i++) {
    await sleep(150);
    const next = await capture(tag);
    if (next.sha === prev.sha) return next;
    prev = next;
  }
  return null;
}

try {
  // NARROWEST sidebar the app allows (250) — the worst case for a chip that has
  // to share a row's width, and the one a "looks fine on my machine" eyeball
  // never sees. `sidebarWidthRange` is 250...420.
  await req("ui.setPanelLayout", { sidebarWidth: 250 }).catch(async () => {
    await req("debug.setPanelLayout", { sidebarWidth: 250 }).catch(() => {});
  });

  await req("project.new", { discardChanges: true });
  const ids = [];
  for (const name of ["GEO-FULL", "GEO-EMPTY-1", "GEO-MID", "GEO-LAST"]) {
    ids.push((await req("track.add", { name, kind: "instrument" })).id);
  }
  for (let i = 0; i < 3; i++) {
    await req("clip.addMIDI", { trackId: ids[0], atBeat: i * 4, lengthBeats: 4 });
  }
  const sel = (p = {}) => req("debug.arrangeSelection", p);

  // Let any acknowledgement from setup expire, then rest.
  await sleep(3400);
  const rest = await stableCapture("rest");
  console.log(`rest       ${rest?.path} ${rest?.width}x${rest?.height}`);

  // G-MID: acknowledge the MIDDLE empty row (index 2 of 4).
  await sel({ act: "clickTrack", trackId: ids[2], modifiers: ["shift"] });
  await sleep(400);
  const mid = await stableCapture("mid");
  const midState = await sel({});
  console.log(`G-MID      ${mid?.path}  ack=${midState.trackClickAck} `
    + `track=${String(midState.trackClickAckTrackId).slice(0, 8)} (expect ${String(ids[2]).slice(0, 8)})`);
  console.log(`           differs from rest: ${mid?.sha !== rest?.sha}`);

  await sleep(3400);

  // G-LAST: acknowledge the LAST row (index 3 of 4) — the likeliest real trigger.
  await sel({ act: "clickTrack", trackId: ids[3], modifiers: ["shift"] });
  await sleep(400);
  const last = await stableCapture("last");
  const lastState = await sel({});
  console.log(`G-LAST     ${last?.path}  ack=${lastState.trackClickAck} `
    + `track=${String(lastState.trackClickAckTrackId).slice(0, 8)} (expect ${String(ids[3]).slice(0, 8)})`);
  console.log(`           differs from rest: ${last?.sha !== rest?.sha}`);
  console.log(`\n⚠️  "differs from rest = false" on G-LAST means the model says the word `
    + `is standing and NO PIXELS CHANGED — i.e. it was clipped away.`);
} finally {
  clearTimeout(killer);
  try { ws.close(); } catch {}
  teardown();
}
