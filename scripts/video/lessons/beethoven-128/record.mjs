// L11 rebuild — THE ONE SCREEN RECORDING, for the thing stills cannot do.
//
// `debug.captureUI` managed 2.59 fps on this project (measured, in shoot.mjs's
// own burst report) and is the default everywhere else here. The transport
// crossing the arrangement while the room arrives strip by strip is the
// exception: a playhead is motion, and a two-and-a-half-frames-a-second
// slideshow of a moving playhead is a slideshow.
//
// ⛔⛔ ONE RULE, AND IT IS ABSOLUTE: `--app DAWApp`, never anything else.
// `--list` on this machine returns over a hundred capturable windows including
// the user's browser, editors and terminals. The tool picks the LARGEST match
// and records it silently, so a mis-target is invisible — the FIRST and LAST
// FRAMES of the recording are extracted and LOOKED AT before it goes near the
// film. Never invoke the binary with no arguments: it does not print help, it
// records some other window for ten seconds.
//
// ⚠ THE FOOTAGE MUST BE THE PASSAGE THAT PLAYS UNDER IT. `play-build.wav` is
// techno.wav from 0.0 s to 12.0 s — the first six bars, where kick, hats, sub
// and clap arrive one at a time. So this records from beat 0, and the first
// frame's transport readout is checked against that.
//
// ⚠ MASTER TO ZERO. Nothing here is an output-fed meter, the audio was rendered
// offline, and the user is asleep.
import { open, cmd, addTrack, addClip, close } from "../../session/build.mjs";
import { PARTS, BPM, LEN_BEATS } from "./material.mjs";
import { spawnSync } from "node:child_process";
import fs from "node:fs";

const HERE = new URL(".", import.meta.url).pathname;
const REC = "/Users/dsemenov/Views/daw-pro/scripts/video/screenrec/screenrec";
const OUT = `${HERE}/media`;
fs.mkdirSync(OUT, { recursive: true });
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

await open();
await cmd("project.new", { discardChanges: true });
await cmd("transport.setTempo", { bpm: BPM });
for (const p of PARTS) {
  const t = await addTrack(p.name, { instrument: p.instrument,
                                     volume: p.volume, pan: p.pan });
  await addClip(t, 0, LEN_BEATS, p.notes, p.name);
}
await cmd("ui.showMixer", { show: false });
await cmd("debug.panelLayout", { editorMaximized: false, editorFraction: 0.32,
                                 followPlayhead: true });
await cmd("debug.followPlayhead", { enabled: true });
await cmd("mixer.setMasterVolume", { volume: 0 });
await cmd("transport.seek", { beats: 0 });
await cmd("transport.play", {});
await sleep(250);
const out = `${OUT}/build.mp4`;
const r = spawnSync(REC, ["--app", "DAWApp", "--out", out,
                          "--seconds", "13", "--fps", "30", "--scale", "2.0"],
                    { encoding: "utf8" });
console.log(`  build.mp4  ${r.status === 0 ? "ok" : "FAILED"}  ${(r.stdout || "").trim()}`);
if (r.status !== 0) console.error(r.stderr);
await cmd("transport.stop", {});
await cmd("mixer.setMasterVolume", { volume: 1 });
await cmd("transport.seek", { beats: 0 });
close();
process.exit(0);
