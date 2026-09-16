// THE PROOF SHOT'S DRIVER. Everything this script does, it does by sending
// JSON messages to the running app over the control socket -- the same socket
// the app's own buttons converge on. It is filmed by screenrec while it runs,
// and the log it writes (`drive-log.json`) is what gets composited back onto
// the frames, so the viewer sees the message and the app's reaction together.
//
// ⚠ STAGING ONLY (17695).
import fs from "node:fs";
import { open, cmd, close } from "../../session/build.mjs";

const HERE = "/Users/dsemenov/Views/daw-pro/scripts/video/series/how-we-built-1";
const ids = JSON.parse(fs.readFileSync(`${HERE}/ids.json`, "utf8"));
const NOTES = JSON.parse(fs.readFileSync(`${HERE}/notes.json`, "utf8"));

const log = [];
let t0 = 0;
const now = () => (Date.now() - t0) / 1000;
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));
const until = async (t) => { const d = t - now(); if (d > 0) await sleep(d); };

// send + log the exact wire text at the exact instant it went out
async function go(method, params = {}, show) {
  const at = now();
  const r = await cmd(method, params);
  log.push({ at: +at.toFixed(3), text: show ?? `${method} ${JSON.stringify(params)}` });
  return r;
}

await open();
await cmd("mixer.setMasterVolume", { volume: 0 });     // nobody asked for noise
await cmd("project.new", { discardChanges: true });
await cmd("transport.setTempo", { bpm: 100 });
await cmd("ui.showMixer", { show: false });
await cmd("debug.panelLayout", { editorMaximized: false, editorFraction: 0.18,
                                 followPlayhead: true });
await sleep(1.0);

t0 = Date.now();
const BANK = "/Users/dsemenov/Library/Audio/Sounds/Banks/GeneralUser-GS.sf2";
const PLAN = [
  { name: "Drums", program: 0,  msb: 120, vol: 0.85, at: 2.0 },
  { name: "Bass",  program: 33, msb: 121, vol: 0.70, at: 4.2 },
  { name: "Keys",  program: 4,  msb: 121, vol: 0.45, at: 6.4 },
  { name: "Pad",   program: 89, msb: 121, vol: 0.28, at: 8.6 },
  { name: "Lead",  program: 81, msb: 121, vol: 0.40, at: 10.8 },
];
const made = {};
for (const p of PLAN) {
  await until(p.at);
  const tr = await go("track.add", { name: p.name, kind: "instrument" },
                      `track.add  {"name":"${p.name}","kind":"instrument"}`);
  made[p.name] = tr.id;
  await cmd("track.setInstrument", { trackId: tr.id, kind: "soundBank",
    soundBank: { source: BANK, program: p.program, bankMSB: p.msb, bankLSB: 0 } });
  await cmd("track.setVolume", { trackId: tr.id, volume: p.vol });
  await until(p.at + 0.9);
  await go("clip.addMIDI", { trackId: tr.id, name: p.name, atBeat: 0,
                             lengthBeats: 32, notes: NOTES[p.name] },
           `clip.addMIDI  {"trackId":"${tr.id.slice(0, 8)}…","atBeat":0,` +
           `"lengthBeats":32,"notes":[ ${NOTES[p.name].length} ]}`);
}

await until(13.4);
await go("transport.setLoop", { enabled: true, startBeat: 0, endBeat: 32 },
         `transport.setLoop  {"enabled":true,"startBeat":0,"endBeat":32}`);
await until(14.2);
await go("transport.play", {}, `transport.play  {}`);
await until(21.5);
await go("transport.stop", {}, `transport.stop  {}`);

await until(22.3);
await go("ui.showMixer", { show: true }, `ui.showMixer  {"show":true}`);
await until(23.6);
// A fader that SLIDES: one command per step, so the picture is the messages.
const kid = made["Keys"];
const N = 26;
for (let i = 0; i <= N; i++) {
  const v = +(0.45 + (0.95 - 0.45) * (i / N)).toFixed(3);
  await until(23.6 + i * 0.115);
  await cmd("track.setVolume", { trackId: kid, volume: v });
  if (i % 4 === 0) log.push({ at: +now().toFixed(3),
    text: `track.setVolume  {"trackId":"${kid.slice(0, 8)}…","volume":${v.toFixed(3)}}` });
}
await until(27.2);
await go("track.setVolume", { trackId: kid, volume: 0.45 },
         `track.setVolume  {"trackId":"${kid.slice(0, 8)}…","volume":0.450}`);
await until(28.4);

fs.writeFileSync(`${HERE}/drive-log.json`, JSON.stringify(log, null, 1));
console.log(`drive: ${log.length} logged commands, ${now().toFixed(1)}s`);
await close();
