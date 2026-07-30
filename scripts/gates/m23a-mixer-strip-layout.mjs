// m23-a mixer-strip layout gate — the insert-chip REGRESSION fix.
//
// Drives INSERT COUNT and WINDOW HEIGHT as independent variables (the clip
// depended on both) across BOTH densities, plus the collapse disclosure, the
// GR mini-bar's liveness inside the new bounded region (the m22-e unpaused-poll
// law), the new Explain card, and the TALLEST master configuration.
//
// CAPTURE-ONLY: no pass/fail assertions — every frame is for pixel review, and
// the thing to check in each is the BOTTOM-MOST control of each strip kind
// (Arm on a channel, Solo on a bus), not merely "the fader is visible".
//
// Staging: this gate BUILDS AND LAUNCHES its own app on 17695 — just run
// `node scripts/gates/m23a-mixer-strip-layout.mjs`. 17600 is the user's LIVE app
// and the harness refuses it outright.
//
// >>> THE `PORT` OVERRIDE IS GONE, AND IT WAS THE DANGEROUS KIND (m23-ac-3c) <<<
// This file used to read `process.env.PORT || "17695"` under a header that
// claimed `DAW_CONTROL_PORT=17695 ONLY`. Both halves of that were wrong and the
// combination was worse than either: the DOCUMENTED variable did nothing (anyone
// who set it got 17695 by accident, not by configuration), while the variable it
// ACTUALLY honoured is `PORT` — one of the most commonly-exported names in any
// shell. A stray `PORT=17600` pointed this gate at the user's live session, where
// its FIRST command is `project.new {discardChanges: true}`. There is no override
// now; `assertStagingPort` refuses 17600 structurally.
//
// Usage: node m23a-mixer-strip-layout.mjs [ABSOLUTE outdir] [prefix]
//   The outdir arg still works and is still resolved by the APP against ITS cwd,
//   so pass an absolute path. Omitted, it defaults to the staging out dir.
// Promoted from the session scratchpad 2026-07-26 (m23-a).
import fs from "fs";
import { buildOrAbort, startStaging, stopStaging, connect } from "./_staging.mjs";

const GATE = "m23a";                                  // names the pidfile + out dir
const OUT = process.argv[2] || `/tmp/daw-gate-out/${GATE}`;
const PREFIX = process.argv[3] || "cap";
const log = (s) => fs.writeSync(1, s + "\n");
fs.mkdirSync(OUT, { recursive: true });
let seq = 0;

function cmd(ws, command, params = {}, timeoutMs = 30000) {
  return new Promise((res, rej) => {
    const id = "m23a-" + (++seq);
    const t = setTimeout(() => rej(new Error(`TIMEOUT ${command}`)), timeoutMs);
    const h = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id !== id) return;
      clearTimeout(t); ws.removeEventListener("message", h); res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id, command, params }));
  });
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

buildOrAbort({ label: "building staging binary (m23a)…" });
startStaging({ gate: GATE });
// Swapping the local connect() for the harness one is a true drop-in HERE, unlike
// m18c/m19f: this gate's cmd() attaches its own per-call `message` listener and
// removes it on reply, so the socket carries no shared reply pump to preserve.
// The harness also retries 40x1 s instead of failing after a single 5 s attempt,
// which is the right budget against a cold boot we now own.
const ws = await connect();
async function must(command, params) {
  log(`> ${command}`);
  const r = await cmd(ws, command, params);
  if (!r.ok) { log(`FAIL ${command}: ${JSON.stringify(r.error)}`); process.exit(1); }
  return r.result;
}
async function cap(name) {
  const r = await must("debug.captureUI", { path: `${OUT}/${PREFIX}-${name}.png` });
  log(`  ${PREFIX}-${name}: ${r.width}x${r.height}`);
}

// ---- session ----
await must("project.new", { discardChanges: true });
const t1 = (await must("track.add", { kind: "instrument", name: "Lead Synth" })).id;
const t2 = (await must("track.add", { kind: "audio", name: "Vox" })).id;
const bus = (await must("track.add", { kind: "bus", name: "Reverb Bus" })).id;
await must("track.addSend", { trackId: t1, busId: bus });
await must("track.addSend", { trackId: t2, busId: bus });

// A FULL chain on track 1 — 8 inserts including a compressor + a gate, both of
// which carry the taller keyable InsertRow (sidechain KEY sub-row).
const chain = ["eq", "compressor", "gate", "saturator", "chorus", "delay", "reverb", "limiter"];
const fxIds = [];
for (const kind of chain) {
  fxIds.push((await must("fx.add", { trackId: t1, kind })).effectId);
}
// NOTE: fx.setSidechain refuses an INSTRUMENT-track destination in v1 (bus-only),
// so the compressor/gate rows here render their KEY sub-row unkeyed — which is
// still the TALL InsertRow variant this gate needs (isKeyable is kind-based).
// A master chain too (master strip is the other host of MixerInsertsSection).
for (const kind of ["eq", "compressor", "limiter"]) {
  await must("fx.add", { trackId: "master", kind });
}
// Non-unity volume/pan so the knobs/readouts show real values.
await must("track.setVolume", { trackId: t1, volume: 1.41 });
await must("track.setPan", { trackId: t1, pan: -0.64 });
await must("track.setVolume", { trackId: t2, volume: 0.5 });
await must("track.setPan", { trackId: t2, pan: 0.3 });

await must("ui.showMixer", { show: true });
log("session ready: " + JSON.stringify({ t1, t2, bus, fx: fxIds.length }));

// ---- sweep: window height x density ----
const heights = [
  { name: "h900", w: 1440, h: 900 },
  { name: "h760", w: 1440, h: 760 },
  { name: "h640", w: 1440, h: 640 },   // the measured window-height FLOOR
];
for (const mode of ["pro", "simple"]) {
  await must("debug.panelDensity", { panel: "mixer", mode });
  for (const s of heights) {
    const f = await must("debug.windowFrame", { width: s.w, height: s.h });
    await sleep(400);
    await cap(`${mode}-${s.name}-full8`);
  }
}

// ---- the COLLAPSE disclosure, at both window heights ----
await must("debug.panelDensity", { panel: "mixer", mode: "pro" });
for (const s of [{ name: "h900", h: 900 }, { name: "h640", h: 640 }]) {
  await must("debug.windowFrame", { width: 1440, height: s.h });
  const r = await must("debug.panelLayout", { mixerInsertsCollapsed: true });
  log("  collapsed echo: " + JSON.stringify(r.mixerInsertsCollapsed));
  await sleep(400);
  await cap(`pro-${s.name}-collapsed`);
  await must("debug.panelLayout", { mixerInsertsCollapsed: false });
  await sleep(300);
}

// ---- insert count as an independent variable, at the SHORT window ----
await must("debug.panelDensity", { panel: "mixer", mode: "pro" });
await must("debug.windowFrame", { width: 1440, height: 640 });
for (const n of [4, 2, 0]) {
  while (fxIds.length > n) {
    const id = fxIds.pop();
    await must("fx.remove", { trackId: t1, effectId: id });
  }
  await sleep(350);
  await cap(`pro-h640-fx${n}`);
}


// ================= extra legs =================
await must("project.new", { discardChanges: true });
const d1 = (await must("track.add", { kind: "audio", name: "Drums" })).id;
for (const kind of ["compressor", "gate", "limiter", "eq", "reverb"]) {
  await must("fx.add", { trackId: d1, kind });
}
for (const kind of ["compressor", "limiter"]) {
  await must("fx.add", { trackId: "master", kind });
}
await must("ui.showMixer", { show: true });
await must("debug.panelDensity", { panel: "mixer", mode: "pro" });

// --- GR mini-bar liveness inside the bounded region (m22-e law) ---
await must("debug.windowFrame", { width: 1440, height: 900 });
await must("debug.grSeed", { db: 0 });
await sleep(500);
await cap("gr-0db");
await must("debug.grSeed", { db: 12 });
await sleep(500);
await cap("gr-12db");
await must("debug.grSeed", { clear: true });

// --- the new Explain card ---
await must("debug.explainMode", { on: true, focus: "mixerVolumeKnob" });
await sleep(600);
await cap("explain-volumeknob");
await must("debug.explainMode", { on: false });
await sleep(300);

// --- the TALLEST master configuration at the window FLOOR: chain + automation
//     lane + reference row, both densities ---
await must("automation.addLane", { trackId: "master", target: { type: "volume" } });
await must("debug.referenceSeed", {
  slot: true, name: "Reference Master.wav", analysis: true,
  integratedLufs: -9.2, truePeakDbtp: -0.8, loudnessRangeLu: 5.1,
  monitoring: false, matchGainDb: -4.6, mix: true, mixLufs: -13.4,
});
await must("debug.windowFrame", { width: 1440, height: 640 });
for (const mode of ["pro", "simple"]) {
  await must("debug.panelDensity", { panel: "mixer", mode });
  await sleep(450);
  await cap(`master-tallest-${mode}-h640`);
}
await must("debug.windowFrame", { width: 1440, height: 900 });
await must("debug.panelDensity", { panel: "mixer", mode: "pro" });
await sleep(450);
await cap("master-tallest-pro-h900");
stopStaging(GATE);   // SIGTERMs by exact pid AND releases our session.lock
ws.close();
log("done");
process.exit(0);
