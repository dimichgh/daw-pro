// m39-pads PROBE — LOOK AT THE PAD GRID.
//
// ⚠️ A PROBE, NOT A GATE. Staging (17695) only; the user's live app on 17600 is
// never touched.
//
// ═══ WHY THIS EXISTS ═══
//
// "A UI phase is not done until someone has looked at it." No headless check in
// this tree can see a pixel, and the pad grid's whole claim is visual: that you
// can tell a LOADED pad from an EMPTY one at a glance, that the pad you are
// sounding is the one that lights, and that the chop card explains the mute
// decision before you make it. Every one of those is green in a unit test over
// a surface that renders as sixteen identical grey boxes.
//
// So this drives the real app and photographs four states:
//   1. the grid over an EMPTY sampler        (all sixteen pads empty)
//   2. the CHOP TO PADS card, Simple         (the mute toggle, named)
//   3. the same card in Pro                  (the pad ceiling / base note)
//   4. the grid AFTER a real chop, with a pad HELD (loaded + lit + the notice)
//
// It also prints the `debug.padGrid` echo beside each shot, so what the model
// believes and what was drawn can be compared rather than assumed.
//
//   node scripts/probes/m39pads-grid-capture.mjs
import {
  buildOrAbort, startStaging, stopStaging, STAGING_PORT, sleep,
} from "../gates/_staging.mjs";
import { mkdirSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const GATE = "m39pads";
const PORT = STAGING_PORT;
const OUT = "/tmp/m39pads";
const PIDFILE = "/tmp/m39pads-staging.pid";

mkdirSync(OUT, { recursive: true });

async function connect() {
  for (let i = 0; i < 60; i++) {
    try {
      const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
      await new Promise((res, rej) => {
        ws.onopen = res;
        ws.onerror = () => rej(new Error("x"));
      });
      let nextId = 1;
      const pending = new Map();
      ws.onmessage = (ev) => {
        let m; try { m = JSON.parse(ev.data); } catch { return; }
        const e = pending.get(m.id); if (!e) return; pending.delete(m.id);
        if (m.ok === false || m.error) {
          e.reject(new Error(`${e.command}: ${JSON.stringify(m.error)}`));
        } else e.resolve(m.result ?? m);
      };
      const req = (command, params = {}) => {
        const id = String(nextId++);
        return new Promise((resolve, reject) => {
          pending.set(id, { resolve, reject, command });
          ws.send(JSON.stringify({ id, command, params }));
          setTimeout(() => {
            if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${command}`)); }
          }, 30000);
        });
      };
      return { ws, req };
    } catch { await sleep(500); }
  }
  throw new Error("no connect");
}

/// A short WAV with four clear transients, written by ffmpeg — real audio, so
/// the detector has something honest to find. ⚠️ NOT silence: a chop of silence
/// would "succeed" with one pad and the capture would show an almost-empty grid
/// that looks exactly like a broken one.
function makeLoop() {
  const path = `${OUT}/loop.wav`;
  const hits = [];
  for (let i = 0; i < 8; i++) {
    const t = i * 0.25;
    const f = 90 + (i % 4) * 180;
    hits.push(`sine=frequency=${f}:duration=0.18,adelay=${Math.round(t * 1000)}|${Math.round(t * 1000)},` +
              `afade=t=out:st=0.05:d=0.12:curve=exp`);
  }
  execFileSync("ffmpeg", [
    "-hide_banner", "-y",
    ...hits.flatMap((h) => ["-f", "lavfi", "-t", "2.2", "-i", h]),
    "-filter_complex", `${hits.map((_, i) => `[${i}:a]`).join("")}amix=inputs=${hits.length}:normalize=0,alimiter=limit=0.9[a]`,
    "-map", "[a]", "-ar", "44100", "-ac", "2", path,
  ], { stdio: "pipe" });
  return path;
}

function show(label, state) {
  const pads = (state.pads || []).map((p) => (p.loaded ? (p.playing ? "◆" : "■") : "·"));
  const rows = [];
  for (let r = 3; r >= 0; r--) rows.push(pads.slice(r * 4, r * 4 + 4).join(" "));
  console.log(`\n--- ${label} ---`);
  console.log(`visible=${state.visible} mode=${state.playMode} bank=${state.bank}/${state.bankCount} ` +
              `base=${state.baseNote} loaded=${state.loadedCount} vel=${state.velocity} ` +
              `target=${JSON.stringify(state.targetName)}`);
  console.log(`blockedBy=${JSON.stringify(state.blockedBy)} chopOpen=${state.chopOpen} ` +
              `mute=${state.muteSourceTrack}`);
  if (state.refusal) console.log(`refusal: ${state.refusal}`);
  if (state.lastChop) console.log(`lastChop: ${JSON.stringify(state.lastChop)}`);
  console.log("grid (top row first; ■ loaded · empty ◆ SOUNDING):");
  for (const row of rows) console.log("   " + row);
}

buildOrAbort({ label: "building staging binary (m39-pads capture)…" });
const { pid } = startStaging({
  gate: GATE, port: PORT, pidfile: PIDFILE, outDir: OUT,
  detached: true, logPath: `${OUT}/staging.log`,
});
console.log(`staging pid ${pid} on :${PORT}`);

let ws;
try {
  await sleep(5000);
  const conn = await connect();
  ws = conn.ws;
  const req = conn.req;

  const loop = makeLoop();
  console.log(`loop: ${loop}`);

  // ── A project with one audio clip ───────────────────────────────────────
  // ⚠️ `project.new` takes ONLY `discardChanges` — it does not name the project.
  await req("project.new", { discardChanges: true });
  const track = await req("track.add", { name: "Break", kind: "audio" });
  const clip = await req("clip.addAudio", {
    trackId: track.id, path: loop, atBeat: 0,
  });
  // A second clip on the same track, so the mute toggle has something to warn
  // about — "its N other clips go quiet too" is a branch a still picture of a
  // one-clip project could never show.
  await req("clip.addAudio", { trackId: track.id, path: loop, atBeat: 8 });

  // ── 1. The grid, empty ──────────────────────────────────────────────────
  // ⚠️ `enable`, NOT `enabled` — the seam ignores unknown keys silently, and
  // the first run of this probe photographed a strip that was never shown.
  await req("debug.musicalTyping", { enable: true });
  await req("debug.musicalTyping", { playMode: "pads" });
  await sleep(600);
  show("1. empty grid", await req("debug.padGrid", {}));
  await req("debug.captureUI", { path: `${OUT}/1-empty-grid.png` });

  // ── 2. The chop card, Simple ────────────────────────────────────────────
  // The REAL click path, so the chop card sees the selection the way a user
  // would make it.
  await req("debug.arrangeSelection", { act: "click", clipId: clip.id });
  await req("debug.padGrid", { openChop: true });
  await sleep(600);
  show("2. chop card (Simple)", await req("debug.padGrid", {}));
  await req("debug.captureUI", { path: `${OUT}/2-chop-simple.png` });

  // ── 3. Pro density ──────────────────────────────────────────────────────
  await req("debug.panelDensity", { panel: "chopToPads", mode: "pro" })
    .catch((e) => console.log(`(density seam unavailable: ${e.message})`));
  await sleep(500);
  await req("debug.captureUI", { path: `${OUT}/3-chop-pro.png` });

  // ── 3b. THE REFUSAL, with both numbers ──────────────────────────────────
  // A cap of 2 against 8 transients: the chop must REFUSE and the card must
  // show the store's own sentence naming 8 and 2.
  // ⚠️ DIVISIONS, not transients: the synthetic loop's attacks are soft and the
  // detector found ONE. A chop of one slice fills one pad, which is
  // indistinguishable in a photograph from a broken grid — and a cap of 2
  // against 1 slice does not refuse, so the refusal shot showed no refusal.
  // Equal pieces is deterministic: 16 asked for, 16 produced.
  await req("debug.padGrid", { mode: "divisions", divisions: 16 });
  await req("debug.padGrid", { maxSlices: 2, chop: true });
  await sleep(2500);
  const refused = await req("debug.padGrid", {});
  show("3b. refusal", refused);
  await req("debug.captureUI", { path: `${OUT}/3b-refusal.png` });

  // ── 4. A real chop, then a HELD pad ─────────────────────────────────────
  await req("debug.padGrid", { maxSlices: 32, muteSourceTrack: true, chop: true });
  await sleep(4000);
  show("4a. after the chop", await req("debug.padGrid", {}));
  await req("debug.captureUI", { path: `${OUT}/4a-chopped.png` });

  // Hold pad 1 near its TOP edge — loud — and photograph it lit.
  await req("debug.padGrid", { padDown: 0, padY: 0.08 });
  await sleep(400);
  const held = await req("debug.padGrid", {});
  show("4b. pad 1 HELD (struck high = loud)", held);
  await req("debug.captureUI", { path: `${OUT}/4b-pad-held.png` });
  await req("debug.padGrid", { padUp: true });

  // Bank 2, so the ordinal continuation is visible.
  await req("debug.padGrid", { bank: 1 });
  await sleep(400);
  show("4c. bank B", await req("debug.padGrid", {}));
  await req("debug.captureUI", { path: `${OUT}/4c-bank-b.png` });

  writeFileSync(`${OUT}/summary.json`, JSON.stringify(
    { held, refusal: refused.refusal }, null, 1));
  console.log(`\ncaptures in ${OUT}`);
} finally {
  try { ws?.close(); } catch {}
  stopStaging(GATE, PIDFILE);
}
