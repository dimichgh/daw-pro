// What clips exist, where, and which one each take would actually open.
//
// ⛔ WHY THIS IS A SCRIPT AND NOT A GUESS. record-motion.mjs picks the clip a
// take opens in the piano roll. A plain first-name-match opens the INTRO clip
// no matter where the transport is, so a take seeking to the breakdown shows
// the roll full of intro notes while breakdown audio plays. Worse, two takes
// seeking to different sections then show the SAME picture — the duplicate-beat
// defect, back again by a different route.
//
// So: print the real layout, and print which clip each `auto` take resolves to.
// If a take's seek lands in no clip of that name, it says so — that take needs
// a different picture or a different cut, and it is much cheaper to learn that
// here than from a finished film.
//
//   DAW_CONTROL_PORT=17695 node probe-clips.mjs [project]
import { open, close, cmd } from "./arrange.mjs";

const proj = process.argv[2] || "machine-room";

await open();
const ov = await cmd("project.overview", {});
const t = ov.transport;
console.log(`${proj}: ${t.tempoBPM} BPM, playhead ${t.positionBeats.toFixed(1)}\n`);

const clips = [];
for (const tr of ov.tracks || []) {
  for (const c of tr.clips || []) {
    clips.push({ track: tr.name, name: c.name ?? "", kind: c.kind,
                 from: c.startBeat, to: c.startBeat + c.lengthBeats,
                 notes: c.noteCount ?? null });
  }
}
console.log("idx  track           clip                  beats          sec       notes");
clips.forEach((c, i) => {
  const s = (b) => (b * 60 / t.tempoBPM).toFixed(0);
  console.log(`[${String(i).padStart(2)}] ${c.track.padEnd(15)} ${c.name.padEnd(20)} ` +
              `${String(c.from).padStart(5)}–${String(c.to).padEnd(6)} ` +
              `${s(c.from).padStart(4)}–${s(c.to).padEnd(5)} ${String(c.notes ?? "").padStart(5)}`);
});

// Exactly the resolution record-motion.mjs performs, on the takes that ask for
// a clip by name — so the answer here IS the answer there.
const TAKES = [
  ["drum-machine", 0, "Drums"],
  ["kits", 62, "Drums"],
  ["honest", 124, "Drums"],
];
// ⚠ THE SAME RULE record-motion.mjs USES — midpoint of the take, not the seek.
// If these two ever disagree the probe is worse than useless, because it
// reports confidently about logic that is not the logic being run.
const HOLD = 22;
const MID = (HOLD / 2) * (t.tempoBPM / 60);

console.log(`\nwhat each take would open (midpoint = seek + ${MID.toFixed(0)} beats):`);
let bad = 0;
const shown = new Map();
for (const [stage, beats, want] of TAKES) {
  const named = clips.filter((c) =>
    `${c.track} / ${c.name}`.toLowerCase().includes(want.toLowerCase()));
  const mid = beats + MID;
  const hit = named.find((c) => mid >= c.from && mid < c.to)
           || named.find((c) => beats >= c.from && beats < c.to);
  if (hit) {
    const k = `${hit.track} / ${hit.name}`;
    const dup = shown.has(k) ? `  ⛔ SAME CLIP AS ${shown.get(k)}` : "";
    if (dup) bad++;
    shown.set(k, stage);
    console.log(`  ${stage.padEnd(14)} beat ${String(beats).padStart(4)} → ${k} ` +
                `(${hit.from}–${hit.to})${dup}`);
  } else {
    bad++;
    console.log(`  ${stage.padEnd(14)} beat ${String(beats).padStart(4)} → ⛔ NO ${want} ` +
                `clip covers this take; would fall back to ` +
                `${named[0] ? `${named[0].track} / ${named[0].name}` : "NOTHING"}`);
  }
}
console.log(bad ? `\n⛔ ${bad} problem(s) — a take would film the wrong clip or repeat another's.`
                : "\n✅ every named take opens its own clip, and the playhead is inside it.");
close();
process.exit(0);
