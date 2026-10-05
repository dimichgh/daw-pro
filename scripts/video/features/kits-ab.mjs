#!/usr/bin/env node
// THE KIT A/B — the film's one "listen to this" moment.
//
// The claim it has to earn: loading a kit is one command, it moves seventeen
// parameters at once, and the result is a different record. A lecture cannot
// carry that; three kicks in a row can.
//
// ⚠ DELIBERATELY SPARSE. Four-on-the-floor kick plus an offbeat hat and nothing
// else, because the thing being compared is the KICK TAIL — 808 rings 0.62 s,
// 909 stops at 0.26 s, trap runs on to 1.45 s. A busy pattern would cover the
// exact difference the narration names.
//
// ⚠ ONE RENDER PER KIT, then concatenated. A preset cannot be swapped part-way
// through a single offline render.
import { open, close, cmd, addTrack, addClip, pattern, layers, VOICE } from "./arrange.mjs";
import path from "node:path";

const DIR = process.env.FEATURES_HOME
  || new URL(".", import.meta.url).pathname.replace(/\/$/, "");
const KITS = ["808", "909", "trap"];
const BARS = 2;

await open();
const out = [];
for (const kit of KITS) {
  await cmd("project.new", { discardChanges: true });
  await cmd("transport.setTempo", { bpm: 128 });
  const drums = await addTrack("Drums", { kind: "drumSynth" }, { volume: 0.9 });
  await cmd("instrument.loadDrumPreset", { trackId: drums, name: kit });

  // PROVE the preset took, per kit, rather than trusting the setter's return.
  const d = await cmd("instrument.describeDrumKit", { trackId: drums });
  const decay = d.voices.kick.parameters.decay.value;
  console.log(`${kit.padEnd(5)} kick.decay = ${decay}s`);

  await addClip(drums, 0, BARS * 4,
    layers(pattern(VOICE.kick, BARS, "X---x---X---x---"),
           pattern(VOICE.closedHat, BARS, "--x---x---x---x-")), `Drums ${kit}`);
  // A limiter so the three clips cannot differ merely by being clipped.
  await cmd("fx.add", { trackId: "master", kind: "limiter" });
  const wav = path.resolve(`${DIR}/loops/_kit-${kit}.wav`);
  await cmd("render.mixdown", { path: wav, durationSeconds: Math.ceil(BARS * 4 * 60 / 128) + 2 });
  out.push({ kit, wav, decay });
}
console.log(JSON.stringify(out));
close();
process.exit(0);
