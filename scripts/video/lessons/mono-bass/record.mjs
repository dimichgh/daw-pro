// L8 rebuild — PASS 1b: SCREEN RECORDINGS, for the one thing stills cannot do.
//
// `debug.captureUI` runs at ~3.5 fps and is the default everywhere else in this
// build. The master strip's MONO SAFETY correlation meter is the exception: it
// is a needle that MOVES while audio plays, and a 3 fps slideshow of it is a
// slideshow of a moving needle. This records the real thing.
//
// ⛔⛔ ONE RULE, AND IT IS ABSOLUTE: --app DAWApp, never anything else. `--list`
// on this machine returns 109 capturable windows including the user's browser,
// editors and terminals. The tool picks the LARGEST match and records it
// silently, so a mis-target is invisible — the FIRST FRAME of every recording
// is looked at before it goes anywhere near the film.
import { open, cmd, addTrack, addClip, n, close } from "../../session/build.mjs";
import { spawnSync } from "node:child_process";
import fs from "node:fs";

const HERE = new URL(".", import.meta.url).pathname;
const REC = "/Users/dsemenov/Views/daw-pro/scripts/video/screenrec/screenrec";
const OUT = `${HERE}/media`;
fs.mkdirSync(OUT, { recursive: true });

const BPM = 100, BEAT_MS = 600;
const E1 = 28, A1 = 33, B1 = 35, D2 = 38, E2 = 40, FS2 = 42, G2 = 43, A2 = 45, C3 = 48;
const BARS = [
  [[0, E1, .45], [.5, E1, .45], [1.5, E1, .45], [2, E2, .45], [3, E1, .45], [3.5, B1, .45]],
  [[0, E1, .45], [.5, E1, .45], [1.5, E2, .45], [2, E1, .45], [2.5, D2, .45], [3.5, E2, .95]],
  [[0, G2, .45], [.5, G2, .45], [1.5, G2, .45], [2, D2, .45], [3, G2, .45], [3.5, A1, .45]],
  [[0, A1, .45], [.5, A1, .45], [1.5, A2, .45], [2, A1, .45], [2.5, C3, .45], [3.5, A1, .95]],
  [[0, E1, .45], [.5, E1, .45], [1.5, E1, .45], [2, E2, .45], [3, E1, .45], [3.5, B1, .45]],
  [[0, E1, .45], [.5, E1, .45], [1.5, E2, .45], [2, E1, .45], [2.5, D2, .45], [3.5, E2, .95]],
  [[0, FS2, .45], [.5, FS2, .45], [1.5, FS2, .45], [2, A1, .45], [3, FS2, .45], [3.5, E2, .45]],
  [[0, E1, .45], [1, E2, .95], [2, E1, .45], [2.5, E1, .45], [3, E2, 1.0]],
];
const RIFF = [];
BARS.forEach((bar, b) => bar.forEach(([o, p, l]) => RIFF.push(n(b * 4 + o, p, l, 108))));
const BASS = { kind: "polySynth", waveform: "saw", attack: 0.005, decay: 0.25,
               sustain: 0.55, release: 0.12, cutoffHz: 1400, resonance: 0.15, gain: 0.55 };
const shift = (notes, d) => notes.map(x => ({ ...x, startBeat: +(x.startBeat + d).toFixed(6) }));
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

await open();
for (const ms of [0, 6]) {
  await cmd("project.new", { discardChanges: true });
  await cmd("transport.setTempo", { bpm: BPM });
  const L = await addTrack("Bass L", { instrument: BASS, pan: -1 });
  const R = await addTrack("Bass R", { instrument: BASS, pan: 1 });
  await addClip(L, 0, 33, RIFF, "Bass L");
  await addClip(R, 0, 33, shift(RIFF, ms / BEAT_MS), "Bass R");
  await cmd("ui.showMixer", { show: true });
  // ⚠ 0.03, not 0: the correlation meter is fed from the OUTPUT and reads a
  // static idle +1.00 at silence. See shoot.mjs for the measurement that found
  // this — the first take reported "IN PHASE" for all three offsets.
  await cmd("mixer.setMasterVolume", { volume: 0.03 });
  await cmd("transport.seek", { beats: 0 });
  await cmd("transport.play", {});
  await sleep(1200);                       // let the meter settle before frame 1
  const out = `${OUT}/mixer${ms}.mp4`;
  const r = spawnSync(REC, ["--app", "DAWApp", "--out", out,
                            "--seconds", "10", "--fps", "30", "--scale", "2.0"],
                      { encoding: "utf8" });
  console.log(`  mixer${ms}.mp4  ${r.status === 0 ? "ok" : "FAILED"}  ${(r.stdout || "").trim()}`);
  if (r.status !== 0) console.error(r.stderr);
  await cmd("transport.stop", {});
  await cmd("mixer.setMasterVolume", { volume: 1 });
}
await cmd("ui.showMixer", { show: false });
close();
process.exit(0);
