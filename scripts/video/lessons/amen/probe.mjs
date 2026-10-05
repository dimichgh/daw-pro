// Measure the GeneralUser-GS drum kit's velocity -> level law BEFORE choosing a
// single velocity for the film. The ghost-note chapter's whole claim is "a
// ghost note is the same drum, hit softer, and here is how much softer" -- so
// the number has to come from the instrument, not from a guess about SF2
// velocity curves.
import { open, cmd, addTrack, close } from "../../session/build.mjs";
import fs from "node:fs";

const GUGS = "/Users/dsemenov/Library/Audio/Sounds/Banks/GeneralUser-GS.sf2";
const KIT = { kind: "soundBank", soundBank: { source: GUGS, program: 0, bankMSB: 120 } };

await open();
await cmd("project.new", { discardChanges: true });
const t = await addTrack("Kit", { instrument: KIT });

const out = {};
// 38 = acoustic snare, 36 = bass drum 1, 51 = ride cymbal 1, 42 = closed hat
for (const [name, pitch] of [["snare", 38], ["kick", 36], ["ride", 51], ["hat", 42]]) {
  const r = await cmd("instrument.probeLiveness", {
    trackId: t, pitch, velocities: [20, 30, 40, 60, 80, 100, 118, 127],
  });
  out[name] = r;
  console.log(name, pitch, r.verdict,
    (r.ladder || []).map(x => `v${x.velocity}:${x.rmsDb.toFixed(2)}dB/${Math.round(x.centroidHz)}Hz`).join("  "));
}
fs.writeFileSync(new URL("./media/_velocity-ladder.json", import.meta.url).pathname,
                 JSON.stringify(out, null, 1));
close(); process.exit(0);
