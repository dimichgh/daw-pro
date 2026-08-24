// _m25j-frame-probe.mjs — A MEASUREMENT INSTRUMENT, NOT A GATE.
// `_`-prefixed so the gate corpus counter skips it as harness.
//
// ⭐ IT ALSO ASKS `quantizeGrid`, WHICH IS NORMALLY EMPTY HERE ON PURPOSE: that
// id is the slot for a PLANTED tag nested INSIDE a clip (an `.overlay` added
// before the offset). Planting it is how the m25-j fix's scope was measured —
// with the offset ALSO inherited down an environment key the planted tag
// reported the offset TWICE (x=554 where the clip drew at 426); with the
// inheritance deleted it lands exactly on the clip's drawn origin. So an
// ancestor's `.offset` IS already in a descendant's frame; only the tagged
// view's OWN offset is missing. An empty list here is the normal state.
//
// ONE QUESTION: what does `debug.explainFrames {ids:["clipBlock"]}` actually
// report for clips that sit on DIFFERENT tracks at DIFFERENT beats — and what
// do the sidebar's `trackRowIdentity` rects report beside them, so the vertical
// row pitch has a SECOND, independent instrument?
//
// Staging port 17695 ONLY (17600 is the user's LIVE app). PIDFILE-EXACT kill.
//
//   node scripts/gates/_m25j-frame-probe.mjs
import fs from "fs";
import { buildOrAbort, startStaging, stopStaging } from "./_staging.mjs";

const GATE = "m25jprobe";
const PORT = "17695";
const OUT = "/tmp/m25j-probe";
const PIDFILE = "/tmp/m25jprobe-staging.pid";
const BINARY = ".build/debug/DAWApp";
const REPO = "/Users/dsemenov/Views/daw-pro";
fs.mkdirSync(OUT, { recursive: true });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 600_000);

buildOrAbort({ root: REPO, skip: process.env.M25J_SKIP_BUILD === "1" });

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
      const raw = (command, params = {}) => {
        const id = String(nextId++);
        return new Promise((resolve) => {
          pending.set(id, { resolve, reject: (e) => resolve({ __error: e.message }), command });
          ws.send(JSON.stringify({ id, command, params }));
          setTimeout(() => {
            if (pending.has(id)) { pending.delete(id); resolve({ __error: `timeout ${command}` }); }
          }, 25000);
        });
      };
      const req = async (c, p) => {
        const r = await raw(c, p);
        if (r && r.__error) throw new Error(r.__error);
        return r;
      };
      return { ws, req, raw };
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
const { ws, req, raw } = await connect();
const teardown = () => { try { stopStaging(GATE, PIDFILE); } catch {} };
for (const ev of ["uncaughtException", "unhandledRejection"]) {
  process.on(ev, (e) => { console.error(`${ev}:`, e && e.message); teardown(); process.exit(2); });
}

try {
  await req("project.new", { discardChanges: true });
  const t = [];
  for (let i = 0; i < 3; i++) t.push((await req("track.add", { kind: "instrument", name: `J${i}` })).id);
  const STARTS = [0, 8, 20];
  for (let i = 0; i < 3; i++) {
    await req("clip.addMIDI", { trackId: t[i], atBeat: STARTS[i], lengthBeats: 4 });
  }
  await req("debug.explainMode", { on: true });
  await sleep(700);
  const zoom = await req("debug.arrangeZoom", {});
  const f = await req("debug.explainFrames", { ids: ["clipBlock", "trackRowIdentity", "quantizeGrid"] });
  console.log("\nzoom:", JSON.stringify(zoom));
  console.log("explainActive:", f.explainActive, " captureOrigin:", JSON.stringify(f.captureOrigin));
  console.log("clipBlock rects:");
  for (const r of f.frames?.clipBlock ?? []) console.log("   ", JSON.stringify(r));
  console.log("quantizeGrid (PLANTED nested tag) rects:");
  for (const r of f.frames?.quantizeGrid ?? []) console.log("   ", JSON.stringify(r));
  console.log("trackRowIdentity rects:");
  for (const r of f.frames?.trackRowIdentity ?? []) console.log("   ", JSON.stringify(r));
  console.log("\nexpected x from beats (startBeat*ppb):", STARTS.map((b) => b * zoom.ppb).join(", "));
  const all = await req("debug.explainFrames", {});
  console.log("\nall reported ids:", Object.keys(all.frames ?? {}).sort().join(" "));
  fs.writeFileSync(`${OUT}/frames.json`, JSON.stringify({ zoom, f, all }, null, 2));
} finally {
  clearTimeout(killer);
  try { ws.close(); } catch {}
  teardown();
}
