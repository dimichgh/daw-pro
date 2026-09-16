// Re-derives m31-f's headline measurement LIVE on staging: the same alto sax
// (GM program 65) from two different sound banks, through the same probe, at
// the same pitch and the same four velocities.
//
// ⚠ It builds ONE throwaway track and REMOVES it, then re-reads project.overview
// to prove the removal. `instrument.probeLiveness` is not itself an edit.
import { open, cmd, close } from "../../session/build.mjs";
import { writeFileSync } from "node:fs";
const HERE = "/Users/dsemenov/Views/daw-pro/scripts/video/series/how-we-built-4";
await open();
const before = await cmd("project.overview", {});
console.log("BEFORE tracks:", before.tracks.length);

const t = await cmd("track.add", { kind: "instrument", name: "HWB4 probe (temporary)" });
const id = t.id || (t.track && t.track.id);
const out = {};
const banks = [
  ["Apple GM DLS", { soundBank: { source: "gm", program: 65 } }],
  ["GeneralUser GS", { soundBank: { source: "/Users/dsemenov/Library/Audio/Sounds/Banks/GeneralUser-GS.sf2", program: 65 } }],
];
for (const [label, inst] of banks) {
  await cmd("track.setInstrument", { trackId: id, kind: "soundBank", ...inst });
  const r = await cmd("instrument.probeLiveness", { trackId: id, pitch: 57,
                        velocities: [25, 60, 95, 127], noteSeconds: 1.0 });
  out[label] = { verdict: r.verdict, ladder: r.ladder, rmsSpreadDb: r.rmsSpreadDb,
                 centroidSpreadPercent: r.centroidSpreadPercent,
                 distinctTimbreCount: r.distinctTimbreCount, selfCheck: r.selfCheck,
                 instrumentDetail: r.instrumentDetail, summary: r.summary };
  console.log(label, r.verdict, JSON.stringify(r.ladder), "spread%", r.centroidSpreadPercent,
              "groups", r.distinctTimbreCount);
}
await cmd("track.remove", { trackId: id });
const after = await cmd("project.overview", {});
console.log("AFTER tracks:", after.tracks.length,
            after.tracks.map(x => x.name).join("/"));
if (after.tracks.length !== before.tracks.length) throw new Error("TRACK NOT REMOVED");
writeFileSync(`${HERE}/liveness.json`, JSON.stringify(
  { out, tracksBefore: before.tracks.length, tracksAfter: after.tracks.length }, null, 1));
await close();
