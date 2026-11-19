#!/usr/bin/env node
// THE NUMBERS THE FILM SPEAKS, measured off the renders of the saved states by
// readers that share nothing with the product (tools/pitch.py, tools/voicesize.py),
// each with a control that must fire first.
//
//   node measure.mjs   -> work/measure/{windows,pitch*,summary}.json
//
// Windows are the SOUR state's own note table (the four phrase ends it moved,
// plus every held note longer than 0.45 s), named by syllable from the melody's
// rhythm (material.mjs): onset (clip s) = (8*line + at - 0.1) * 0.6.
import { mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { open, close, VOICE_HOME } from "./wire.mjs";
import { openState, edits } from "./states.mjs";
import { LYRICS } from "./material.mjs";

const M = `${VOICE_HOME}/work/measure`;
const R = `${VOICE_HOME}/out/renders`;
const PY = "/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python";
mkdirSync(M, { recursive: true });
const AT = [0.5, 1.0, 1.5, 2.0, 3.0, 3.5, 4.5, 5.0];
const PITCH = [[66, 66, 64, 66, 69, 66, 64, 62], [62, 66, 66, 69, 66, 64, 62, 64],
               [66, 69, 69, 71, 67, 69, 67, 66], [66, 69, 66, 64, 62, 64, 66, 62]];
const SYL = LYRICS.split("\n").map((l) => l.replace(/[,.]/g, "").split(/[\s-]+/));
const syllables = [];
for (let L = 0; L < 4; L++) for (let k = 0; k < 8; k++)
  syllables.push({ word: SYL[L][k], onset: (8 * L + AT[k] - 0.1) * 0.6, target: PITCH[L][k] });
const nameAt = (t) => syllables.reduce((best, s) => (Math.abs(s.onset - t) < Math.abs(best.onset - t) ? s : best));

await open();
let segs;
try {
  await openState("sour");
  segs = (await edits()).segments;
} catch (err) {
  console.error("⛔", err?.stack || err); process.exitCode = 1;
} finally { close(); }
if (process.exitCode) process.exit(1);

const sour = segs.filter((s) => Math.abs(s.pitchOffsetCents - 70) < 0.5);
const held = segs.filter((s) => s.origin === "detected" && s.endSeconds - s.startSeconds > 0.45
                                 && !sour.includes(s));
const win = (s, tag) => { const n = nameAt(s.startSeconds);
  return { name: `${tag} ${n.word}`, start: s.startSeconds, end: s.endSeconds, target: n.target }; };
const windows = [...sour.map((s) => win(s, "SOUR")), ...held.map((s) => win(s, "held"))];
writeFileSync(`${M}/windows.json`, JSON.stringify(windows, null, 1));

const py = (args) => execFileSync(PY, args, { encoding: "utf8" });
// controls first: the reader must read a known tone right, flat as flat
console.log(py([`${VOICE_HOME}/tools/pitch.py`, `${VOICE_HOME}/work/pitch-selftest.json`]));
const spec = (name, wavs) => { const p = `${M}/${name}.json`;
  writeFileSync(p, JSON.stringify({ windows, wavs }, null, 1)); return p; };
const p1 = spec("pitch", Object.fromEntries(["sung", "sour", "tuned", "hard", "deeper"]
  .map((s) => [s, `${R}/${s}-vocal.wav`])));
console.log(py([`${VOICE_HOME}/tools/pitch.py`, p1]));
const pr = JSON.parse(readFileSync(p1.replace(".json", ".out.json"), "utf8"));

const vs = py([`${VOICE_HOME}/tools/voicesize.py`, "--control", `${R}/tuned-vocal.wav`,
               `${R}/octave-keep-vocal.wav`, `${R}/octave-off-vocal.wav`]);
console.log(vs);
// the Voice tool's last line (clip 14.5–18.75 s), tuned vs deeper
for (const s of ["tuned", "deeper"])
  execFileSync("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", "-ss", "14.5", "-to", "18.75",
                          "-i", `${R}/${s}-vocal.wav`, `${M}/line4-${s}.wav`]);
const vl = py([`${VOICE_HOME}/tools/voicesize.py`, `${M}/line4-tuned.wav`, `${M}/line4-deeper.wav`]);
console.log(vl);

// ---- the summary the narration reads
const S = (st) => windows.filter((w) => w.name.startsWith("SOUR")).map((w) => pr[st][w.name]?.centsVsTarget);
const vib = windows.filter((w) => (pr.tuned[w.name]?.wobbleCentsP95P5 ?? 0) > 45).map((w) => w.name);
const mean = (a) => a.reduce((x, y) => x + y, 0) / a.length;
const summary = {
  sourCents: { sung: S("sung"), sour: S("sour"), tuned: S("tuned") },
  heldInvariance: windows.filter((w) => w.name.startsWith("held"))
    .map((w) => [w.name, pr.sung[w.name]?.centsVsTarget, pr.sour[w.name]?.centsVsTarget]),
  vibratoNotes: vib,
  wobbleNatural: vib.map((n) => pr.tuned[n].wobbleCentsP95P5),
  wobbleHard: vib.map((n) => pr.hard[n].wobbleCentsP95P5),
  voiceSize: vs.trim().split("\n"),
  voiceTool: vl.trim().split("\n"),
};
summary.wobbleMeanNatural = +mean(summary.wobbleNatural).toFixed(1);
summary.wobbleMeanHard = +mean(summary.wobbleHard).toFixed(1);
writeFileSync(`${M}/summary.json`, JSON.stringify(summary, null, 1));
console.log(JSON.stringify(summary, null, 1));
process.exit(0);
