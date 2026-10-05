#!/usr/bin/env node
// demo-harness-audio.mjs — the headless demo harness must be able to demo an
// effect on a REAL RECORDING, not only on synthesised MIDI.
//
// WHY THIS EXISTS (2026-09-19). Until today `DemoRender` implemented neither
// `clip.addAudio` nor `clip.sliceToSampler`, so every demo in this tree ran on
// material the harness generated itself. Nothing had ever proved an effect on
// recorded audio, and nothing could demo the sample-flip chop at all — the
// capability the user asked about by name. Both were added; this gate is what
// keeps them working.
//
// ⚠️ IT GENERATES ITS OWN SOURCE AUDIO. Committing a multi-second WAV to guard
// this would put a binary in a repo whose effect commit deliberately contained
// none, and a fixture that lives in /tmp is a gate that silently stops running.
// ffmpeg synthesises four separated tone bursts — deterministic, and shaped so
// the transient detector has something unambiguous to find.
//
// ⭐ IT PROVES IT CAN FAIL. A gate that has never failed is indistinguishable
// from one that cannot: this tree has shipped features whose whole suite could
// not redden. So the run ends with a NEGATIVE CONTROL — a spec carrying a key
// the harness must reject — and the gate fails if that spec SUCCEEDS.
//
// Exit codes: 0 pass · 1 the harness lost a capability · 3 COULD NOT SELF-TEST.

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const HARNESS = "scripts/demos/render-variants.mjs";
const work = mkdtempSync(join(tmpdir(), "demo-harness-audio-"));
const cleanup = () => { try { rmSync(work, { recursive: true, force: true }); } catch {} };

function die(code, msg) { console.error(msg); cleanup(); process.exit(code); }

// ---- source audio: four bursts, so transient detection has real onsets -----
const SRC = join(work, "bursts.wav");
const ff = spawnSync("ffmpeg", [
  "-hide_banner", "-y",
  "-f", "lavfi", "-i",
  // 4 bursts of 0.25 s separated by 0.35 s of silence, 48 kHz stereo.
  "sine=frequency=440:duration=3,volume='if(lt(mod(t,0.6),0.25),1,0)':eval=frame",
  "-ac", "2", "-ar", "48000", "-c:a", "pcm_s16le", SRC,
], { encoding: "utf8" });
if (ff.status !== 0 || !existsSync(SRC)) {
  die(3, `SELF-TEST FAILED: could not synthesise source audio with ffmpeg.\n${ff.stderr ?? ""}`);
}

const specFor = (variants) => ({ set: "harness-audio-gate", description: "gate", variants });

const audioVariant = (extra = []) => ({
  name: "audio", axis: "gate", render: { durationSeconds: 4 },
  commands: [
    { command: "track.add", params: { name: "Src", kind: "audio" }, as: "src" },
    { command: "clip.addAudio", params: { trackId: "$src", atBeat: 0, path: SRC }, as: "clip" },
    ...extra,
  ],
});

function runSpec(spec, outName) {
  const p = join(work, `${outName}.json`);
  writeFileSync(p, JSON.stringify(spec));
  const r = spawnSync("node", [HARNESS, p, "--skip-build", `--out=${join(work, outName)}`],
    { cwd: ROOT, encoding: "utf8" });
  return { status: r.status, out: `${r.stdout ?? ""}${r.stderr ?? ""}` };
}

// ---- LEG 1: a real recording reaches the render --------------------------
const leg1 = runSpec(specFor([audioVariant()]), "leg1");
if (leg1.status !== 0) {
  die(1, `clip.addAudio NO LONGER WORKS — the harness cannot import a recording.\n` +
         `Without it no demo can show an effect on real audio.\n\n${leg1.out.slice(-1400)}`);
}

// ---- LEG 2: the sample-flip chop reaches the render ----------------------
const leg2 = runSpec(specFor([audioVariant([
  { command: "clip.sliceToSampler", params: {
      clipId: "$clip", mode: "divisions", divisions: 6, maxSlices: 16,
      baseNote: 36, generateMIDI: true, atBeat: 0 }, as: "pads" },
  { command: "track.setVolume", params: { trackId: "$src", volume: 0.0 } },
])]), "leg2");
if (leg2.status !== 0) {
  die(1, `clip.sliceToSampler NO LONGER WORKS — the harness cannot demo a chop.\n\n` +
         `${leg2.out.slice(-1400)}`);
}
// Non-vacuity: the chop must REPORT pads, or it "succeeded" having done nothing.
const chopLine = /# chop: (\d+) slice\(s\)/.exec(leg2.out);
if (!chopLine) {
  die(1, `the chop ran without reporting any slices — a chop that silently makes ` +
         `zero pads renders a silent file and still exits 0.\n\n${leg2.out.slice(-1200)}`);
}
const slices = Number(chopLine[1]);
if (slices < 2) {
  die(1, `the chop reported ${slices} slice(s); 6 divisions were requested. A chop ` +
         `that collapses to one pad is not a chop.`);
}

// ---- NEGATIVE CONTROL: the harness must REJECT an unknown key ------------
// `track.setInstrument` once accepted `unisonVoices` and threw it away, and four
// "different" variants rendered byte-identical. Both commands this gate guards
// carry unknown-key rejection; if that ever regresses to silent acceptance,
// this gate's two passing legs would mean nothing.
const neg = runSpec(specFor([audioVariant([
  { command: "clip.sliceToSampler", params: {
      clipId: "$clip", mode: "divisions", divisions: 6,
      thisKeyDoesNotExist: 1 }, as: "pads" },
])]), "neg");
if (neg.status === 0) {
  die(1, `⚠️ SELF-CONTROL FAILED — the harness ACCEPTED an unknown key on ` +
         `clip.sliceToSampler instead of refusing it. A setting accepted and ` +
         `discarded is indistinguishable from a setting that does not work, and ` +
         `this gate's passing legs above therefore prove nothing.`);
}

console.log(
  `demo-harness-audio: OK — clip.addAudio imports a recording, ` +
  `clip.sliceToSampler made ${slices} pads from 6 divisions, and an unknown key ` +
  `is still refused (negative control fired).`);
cleanup();
