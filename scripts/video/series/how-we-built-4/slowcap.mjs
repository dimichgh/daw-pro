// FILM THE APP THE ONLY WAY AVAILABLE RIGHT NOW: debug.captureUI, in a loop,
// while the transport rolls. This is NOT a workaround dressed as footage — it
// is the §5 limitation itself, filmed at its real rate so the film can SHOW
// what 3.5 frames a second looks like instead of asserting it.
// ⚠ STAGING ONLY. ⚠ Master to 0 while the transport runs.
import { open, cmd, close } from "../../session/build.mjs";
import { writeFileSync, mkdirSync } from "node:fs";
const HERE = "/Users/dsemenov/Views/daw-pro/scripts/video/series/how-we-built-4";
const DIR = `${HERE}/media/slowcap`;
mkdirSync(DIR, { recursive: true });
const SECS = Number(process.env.SECS || 12);
await open();
await cmd("debug.clearModals", {}).catch(() => {});
await cmd("ui.showMixer", { show: false });
await cmd("debug.panelLayout", { editorMaximized: false, editorFraction: 0.30 });
await cmd("debug.followPlayhead", { enabled: true }).catch(() => {});
await cmd("transport.seek", { beats: 0 });
const m0 = (await cmd("project.overview", {})).master.volume;
await cmd("mixer.setMasterVolume", { volume: 0 });

const t0 = Date.now();
await cmd("transport.play", {});
const stamps = [];
let i = 0;
while ((Date.now() - t0) / 1000 < SECS) {
  const a = Date.now();
  await cmd("debug.captureUI", { path: `${DIR}/c${String(i).padStart(4, "0")}.png` });
  stamps.push({ i, t: (a - t0) / 1000, ms: Date.now() - a });
  i++;
}
await cmd("transport.stop", {});
await cmd("transport.seek", { beats: 0 });
await cmd("mixer.setMasterVolume", { volume: m0 });
await cmd("debug.followPlayhead", { enabled: false }).catch(() => {});
const span = stamps[stamps.length - 1].t - stamps[0].t;
const fps = (stamps.length - 1) / span;
const msMean = stamps.reduce((s, x) => s + x.ms, 0) / stamps.length;
console.log(`captured ${stamps.length} frames over ${span.toFixed(3)}s = ${fps.toFixed(2)} fps`
            + `  (mean ${msMean.toFixed(0)} ms per capture); master back to ${m0}`);
writeFileSync(`${HERE}/slowcap.json`, JSON.stringify(
  { frames: stamps.length, spanSeconds: +span.toFixed(3), fps: +fps.toFixed(2),
    meanMsPerCapture: +msMean.toFixed(1), stamps }, null, 1));
await close(); process.exit(0);
