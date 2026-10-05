#!/usr/bin/env node
// THREE LEAD SOUNDS, ONE AXIS APART — pick one.
//
// ⛔ WHY: the user heard the film and said the lead "is cheap, like toy". They
// were right, and the cause was not taste — it was that the patch used EIGHT of
// the synth's TWENTY-FOUR parameters. `unisonVoices` defaults to 1, so the lead
// was a SINGLE CLEAN OSCILLATOR: no detune, no sub, no drift, no drive, no
// per-note jitter. That is the definition of a toy synth sound, and no amount of
// effects downstream fixes a one-oscillator source.
//
// Same notes, same drums, same bass, same effects, same level. ONLY the lead
// patch changes, so whichever one is preferred, the preference means something.
import { open, close, cmd, addTrack, addClip, addFx, pattern, layers, VOICE } from "./arrange.mjs";
import { MACHINE_ROOM, bassLine, motif } from "./material.mjs";
// ⚠ THE PATCHES MOVED OUT to leads.mjs so build.mjs can import them WITHOUT
// importing this file — this one is a script and its top level destroys three
// projects and writes three renders.
import { LEADS } from "./leads.mjs";
import path from "node:path";

const DIR = "/Users/dsemenov/Views/daw-pro/scripts/video/features";
const BARS = 8;

// The three candidates now live in leads.mjs — data only, imported above.
// They were moved out so build.mjs could reuse the winning patch without
// importing THIS file, whose top level rebuilds and re-renders all three.

await open();
const out = [];
for (const [name, patch] of Object.entries(LEADS)) {
  await cmd("project.new", { discardChanges: true });
  await cmd("transport.setTempo", { bpm: 128 });

  const drums = await addTrack("Drums", { kind: "drumSynth" }, { volume: 0.85 });
  await cmd("instrument.loadDrumPreset", { trackId: drums, name: "909" });
  await addClip(drums, 0, BARS * 4,
    layers(pattern(VOICE.kick, BARS, "X---x---X---x---"),
           pattern(VOICE.closedHat, BARS, "--x---x---x---x-"),
           pattern(VOICE.clap, BARS, "----X-------X---")), "Drums");

  const bass = await addTrack("Bass", {
    kind: "polySynth", waveform: "saw", cutoffHz: 900, resonance: 0.18,
    attack: 0.004, decay: 0.12, sustain: 0.55, release: 0.09, gain: 0.85,
  }, { volume: 0.8 });
  await addClip(bass, 0, BARS * 4, bassLine(MACHINE_ROOM.bassRoots, BARS), "Bass");

  const lead = await addTrack("Lead", patch, { volume: 0.72, pan: 0.1 });
  await addClip(lead, 0, BARS * 4,
    motif(MACHINE_ROOM.lead, MACHINE_ROOM.leadBars, BARS), "Lead");
  // The same modest polish on every option, so the axis stays the patch.
  await addFx(lead, "tapeDelay", { timeMs: 234, feedback: 0.3, mix: 0.22 });
  await addFx("master", "limiter", { ceilingDb: -1.0, truePeak: 1, releaseMs: 80 });

  // A setter's return is not proof: read the stack back.
  const d = await cmd("instrument.describeSynth", { trackId: lead });
  const P = d.parameters || d.params || d;
  const got = { voices: P.unisonVoices?.value, detune: P.unisonDetuneCents?.value,
                sub: P.subLevel?.value, drive: P.drive?.value,
                resBoost: P.resonanceBoost?.value };
  const wav = path.resolve(`${DIR}/out/leads/${name}.wav`);
  await cmd("render.mixdown", { path: wav, durationSeconds: Math.ceil(BARS * 4 * 60 / 128) + 2 });
  console.log(`${name.padEnd(9)} ${JSON.stringify(got)}`);
  out.push({ name, wav });
}
console.log(JSON.stringify(out));
close();
process.exit(0);
