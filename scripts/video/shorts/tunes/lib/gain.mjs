// Steer the master `gain` insert until the MIX measures the target, then
// re-render. The bounce's own lufsTarget is deliberately NOT used: its gain is
// applied after the whole master chain and clamped by the post-chain true peak,
// so it lands short and says so only in a field you have to remember to read.
import { open, cmd, close } from "/Users/dsemenov/Views/daw-pro/scripts/video/session/build.mjs";
import fs from "node:fs";
import path from "node:path";
// ⚠⚠ RESOLVE THE OUT DIR. `render.mixdown` takes a path over the WIRE and the
// APP resolves a relative one against ITS OWN cwd -- and answers `ok` with a
// real wav at a plausible name. MEASURED IN THIS BUILD: passing "out" wrote
// 17.9 MB to <repo>/out/music.wav while the film downstream happily used the
// STALE file beside the song, so the short shipped 5.1 dB louder than the mix
// this script had just converged, and every printed number said otherwise.
const [songPathRaw, outDirRaw, targetS] = process.argv.slice(2);
const songPath = path.resolve(songPathRaw);
const outDir = path.resolve(outDirRaw);
const song = JSON.parse(fs.readFileSync(songPath, "utf8"));
const target = parseFloat(targetS || "-14");
await open();
// ⚠ project.overview OMITS the master chain — project.snapshot carries it as
// `masterEffects`. Reading the id from the wrong call answers `undefined`.
const snap = await cmd("project.snapshot", {});
const g = (snap.masterEffects || []).find((f) => f.kind === "gain");
if (!g) throw new Error("no gain insert on the master chain");
let gain = g.params.gainLinear, m = null;
for (let i = 0; i < 7; i++) {
  await cmd("fx.setParam", { trackId: "master", effectId: g.id, name: "gainLinear", value: gain });
  m = (await cmd("render.measureLoudness", { fromBeat: 0, durationSeconds: song.renderSeconds })).measurement;
  const err = target - m.integratedLufs;
  console.log(`  gain ${gain.toFixed(3)} -> ${m.integratedLufs.toFixed(2)} LUFS / ${m.truePeakDbtp.toFixed(2)} dBTP  (err ${err.toFixed(2)})`);
  if (Math.abs(err) <= 0.25) break;
  // A limiter under the gain means the response is sub-unity, so step by the
  // error and re-measure rather than solving for it in one go.
  gain = Math.max(0.05, Math.min(16, gain * Math.pow(10, err / 20)));
}
const want = `${outDir}/music.wav`;
const r = await cmd("render.mixdown", { path: want, fromBeat: 0, durationSeconds: song.renderSeconds });
if (r.path !== want) throw new Error(`render wrote ${r.path}, not ${want}`);
// ⭐ WRITE THE CONVERGED GAIN BACK INTO song.json. Otherwise a rebuild from the
// spec silently re-ships the un-converged number that was only ever a guess.
for (const f of song.master.fx) if (f.kind === "gain") f.params.gainLinear = +gain.toFixed(4);
fs.writeFileSync(songPath, JSON.stringify(song, null, 1));
fs.writeFileSync(`${outDir}/loudness.json`, JSON.stringify({ gainLinear: gain, measurement: m, render: { path: r.path, seconds: r.durationSeconds } }, null, 1));
console.log("FINAL " + JSON.stringify({ gainLinear: +gain.toFixed(3), ...m }));
close(); process.exit(0);
