// L6 rebuild — PASS 1b: THE ONE SCREEN RECORDING, for the thing stills cannot do.
//
// `debug.captureUI` runs at ~3.3 fps (measured in this very build: the
// c14-arrange burst came back at 3.30 fps) and is the default everywhere else
// here. The transport crossing the arrangement is the exception: a playhead is
// motion, and a three-frames-a-second slideshow of a moving playhead is a
// slideshow. This records the real thing at 30.
//
// ⛔⛔ ONE RULE, AND IT IS ABSOLUTE: `--app DAWApp`, never anything else.
// `--list` on this machine returns over a hundred capturable windows including
// the user's browser, editors and terminals. The tool picks the LARGEST match
// and records it silently, so a mis-target is invisible — the FIRST FRAME of
// every recording is extracted and looked at before it goes near the film.
//
// ⚠ MEASURED THE HARD WAY DURING THIS BUILD: running the binary with NO
// arguments does not print help. It records the *Dock* — i.e. some window that
// is not DAW Pro — for ten seconds and writes screenrec.mp4 beside itself. That
// file was deleted immediately. Never invoke it without --app.
//
// ⚠ MASTER TO ZERO, not 0.03. Nothing in THIS recording is a meter fed from the
// output; the playhead moves whether or not audio is audible, and the user is
// asleep (system output volume measured at 38, not muted).
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
// ⚠ START AT BAR 10, NOT BAR 1. The excerpt this footage plays under
// (`ab-dry.wav`) is cut at 21.6 s = beat 36 = bar 10, where all four parts
// are sounding. Recording from beat 0 put a full kit and a lead on the
// soundtrack while the picture showed the drums not yet started. 34.8 rather
// than 36 because the 600 ms sleep plus the recorder's own start-up put the
// first frame about 1.2 beats after the seek (measured on the first take).
await cmd("transport.seek", { beats: 34.8 });
await cmd("transport.play", {});
await sleep(600);
const out = `${OUT}/arrange.mp4`;
const r = spawnSync(REC, ["--app", "DAWApp", "--out", out,
                          "--seconds", "10", "--fps", "30", "--scale", "2.0"],
                    { encoding: "utf8" });
console.log(`  arrange.mp4  ${r.status === 0 ? "ok" : "FAILED"}  ${(r.stdout || "").trim()}`);
if (r.status !== 0) console.error(r.stderr);
await cmd("transport.stop", {});
await cmd("mixer.setMasterVolume", { volume: 1 });
await cmd("transport.seek", { beats: 0 });
close();
process.exit(0);
