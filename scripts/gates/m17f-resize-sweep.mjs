// m17-f resize sweep — window-size matrix (debug.windowFrame; OS clamps HEIGHT to the display, width unclamped)
// x ARRANGE/MIX x Simple/Pro + captureUI frames for pixel review. Pairs with m17f-barlines detector below.
// Staging: DAW_CONTROL_PORT=17695. Promoted from session scratchpad 2026-07-16 (m17-g).
// m17-f resize sweep: sizes x surfaces x densities, capture each frame.
// Pass 1 (editor closed): arrange Simple / arrange Pro / mix Simple / mix Pro.
// Pass 2 (piano roll open on the CC clip): arrange Pro + controller strip,
//          then the same with an effect-editor card open.
// Resize via debug.windowFrame (AppleScript impossible on the unbundled
// staging binary — m17-b measured), settle ~300 ms after each stage.
// Usage: node sweep.mjs <outdir> [ccClipId eqTrackId eqEffectId]
const PORT = process.env.PORT || "17695";
const OUT = process.argv[2];
const CC_CLIP = process.argv[3];
const EQ_TRACK = process.argv[4];
const EQ_FX = process.argv[5];
import fs from "fs";
fs.mkdirSync(OUT, { recursive: true });
let seq = 0;

function connect(timeoutMs = 5000) {
  return new Promise((res, rej) => {
    const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
    const t = setTimeout(() => rej(new Error("connect timeout")), timeoutMs);
    ws.onopen = () => { clearTimeout(t); res(ws); };
    ws.onerror = () => { clearTimeout(t); rej(new Error("connect failed")); };
  });
}
function cmd(ws, command, params = {}, timeoutMs = 30000) {
  return new Promise((res, rej) => {
    const id = "swp-" + (++seq);
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
const ws = await connect();
async function must(command, params) {
  const r = await cmd(ws, command, params);
  if (!r.ok) { console.error(`FAIL ${command}: ${JSON.stringify(r.error)}`); process.exit(1); }
  return r.result;
}
async function cap(name) {
  const r = await must("debug.captureUI", { path: `${OUT}/${name}.png` });
  console.log(`${name}: ${r.width}x${r.height}`);
}

const sizes = [
  { name: "s1208x760", w: 1200, h: 760 },   // clamps to the 1208 floor width
  { name: "s1440x900", w: 1440, h: 900 },
  { name: "s1728x1080", w: 1728, h: 1080 },
  { name: "smax", w: 3456, h: 2234 },        // echo reports the real landing size
];

// ---- pass 1: editor closed ----
for (const s of sizes) {
  const f = await must("debug.windowFrame", { width: s.w, height: s.h });
  await sleep(350);
  console.log(`# size ${s.name} -> ${f.width}x${f.height}`);
  await must("ui.showMixer", { show: false });
  await must("debug.panelDensity", { panel: "arrange", mode: "simple" });
  await must("debug.panelDensity", { panel: "transport", mode: "simple" });
  await sleep(300);
  await cap(`${s.name}-arr-simple`);
  await must("debug.panelDensity", { panel: "arrange", mode: "pro" });
  await must("debug.panelDensity", { panel: "transport", mode: "pro" });
  await sleep(300);
  await cap(`${s.name}-arr-pro`);
  await must("ui.showMixer", { show: true });
  await must("debug.panelDensity", { panel: "mixer", mode: "simple" });
  await sleep(300);
  await cap(`${s.name}-mix-simple`);
  await must("debug.panelDensity", { panel: "mixer", mode: "pro" });
  await sleep(300);
  await cap(`${s.name}-mix-pro`);
}

// ---- pass 2: piano roll open (CC clip), Pro everywhere ----
if (CC_CLIP) {
  await must("ui.showMixer", { show: false });
  await must("debug.panelDensity", { panel: "pianoRoll", mode: "pro" });
  for (const s of sizes) {
    const f = await must("debug.windowFrame", { width: s.w, height: s.h });
    await sleep(350);
    // selectClip opens the piano roll and leaves it open
    await must("debug.captureUI", { path: `${OUT}/tmp-select.png`, selectClip: CC_CLIP });
    await sleep(300);
    await cap(`${s.name}-arr-pro-editor`);
    if (EQ_TRACK && EQ_FX) {
      await must("debug.effectEditor", { trackId: EQ_TRACK, effectId: EQ_FX, open: true });
      await sleep(300);
      await cap(`${s.name}-arr-pro-fxcard`);
      await must("debug.effectEditor", { close: true });
      await sleep(200);
    }
  }
  fs.rmSync(`${OUT}/tmp-select.png`, { force: true });
}
console.log("sweep done");
ws.close();
process.exit(0);
