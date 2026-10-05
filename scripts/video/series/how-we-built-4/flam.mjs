// THE AUDIBLE HALF OF THE PDC CHAPTER.
//
// The bug this film plants cannot be turned on from the wire: there is no
// "PDC off" switch, and inventing one would be a different program. What CAN
// be done honestly is to let the viewer hear the SIZE of the error the test
// measures — 4096 samples at 48 kHz is 85.333 ms — by putting the same two
// hits together and then 85.333 ms apart. The film labels it as exactly that:
// "this is what eighty-five milliseconds apart sounds like", never "this is
// the bug".
//
// ⚠ Builds ONE temporary track, renders twice, REMOVES it, and re-reads
// project.overview to prove the removal. STAGING ONLY (17695).
import { open, cmd, close } from "../../session/build.mjs";
import { writeFileSync } from "node:fs";
const HERE = "/Users/dsemenov/Views/daw-pro/scripts/video/series/how-we-built-4";

const SR = 48000, LATENCY_SAMPLES = 4096, BPM = 100;
const OFFSET_SECONDS = LATENCY_SAMPLES / SR;              // 0.0853333...
const OFFSET_BEATS   = OFFSET_SECONDS * BPM / 60;         // 0.1422222...

await open();
const before = await cmd("project.overview", {});
// Mute the real project so the render is the demonstration and nothing else.
for (const t of before.tracks) await cmd("track.setMute", { trackId: t.id, muted: true });

const t = await cmd("track.add", { kind: "instrument", name: "HWB4 flam (temporary)" });
const id = t.id || (t.track && t.track.id);
await cmd("track.setInstrument", { trackId: id, kind: "soundBank",
                                   soundBank: { source: "gm", program: 115 } }); // Woodblock
const PITCH = 76, VEL = 110, HITS = 6, EVERY = 2; // a hit every 2 beats = 1.2 s

const build = async (offsetBeats) => {
  const notes = [];
  for (let i = 0; i < HITS; i++) {
    notes.push({ startBeat: i * EVERY,                pitch: PITCH, lengthBeats: 0.5, velocity: VEL });
    notes.push({ startBeat: i * EVERY + offsetBeats,  pitch: PITCH, lengthBeats: 0.5, velocity: VEL });
  }
  return notes;
};

const results = {};
for (const [name, off] of [["together", 0], ["apart", OFFSET_BEATS]]) {
  const ov = await cmd("project.overview", {});
  const mine = ov.tracks.find(x => x.id === id);
  for (const c of mine.clips) await cmd("clip.remove", { clipId: c.id });
  await cmd("clip.addMIDI", { trackId: id, atBeat: 0, lengthBeats: HITS * EVERY,
                              notes: await build(off), name: `flam-${name}` });
  const r = await cmd("render.mixdown", { path: `${HERE}/audio/flam-${name}.wav`,
                                          fromBeat: 0, durationSeconds: 7.5, bitDepth: 24 });
  results[name] = { path: r.path, offsetBeats: off, offsetSeconds: off * 60 / BPM };
  console.log(name, "->", r.path, "offset", off, "beats =", (off * 60 / BPM * 1000).toFixed(3), "ms");
}

await cmd("track.remove", { trackId: id });
for (const t2 of before.tracks) await cmd("track.setMute", { trackId: t2.id, muted: false });

// ⚠ RE-READ, field for field. A setter's return is not proof.
const after = await cmd("project.overview", {});
console.log("AFTER tracks:", after.tracks.length,
            after.tracks.map(x => `${x.name}:muted=${x.muted}`).join(" "));
if (after.tracks.length !== before.tracks.length) throw new Error("TEMP TRACK NOT REMOVED");
if (after.tracks.some(x => x.muted)) throw new Error("A TRACK IS STILL MUTED");
writeFileSync(`${HERE}/flam.json`, JSON.stringify(
  { results, offsetSeconds: OFFSET_SECONDS, latencySamples: LATENCY_SAMPLES,
    sampleRate: SR, bpm: BPM, pitch: PITCH, velocity: VEL, hits: HITS,
    program: 115, programName: "Woodblock" }, null, 1));
await close();
