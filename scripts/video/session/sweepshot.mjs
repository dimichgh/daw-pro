// Shoot a CONTROL BEING MOVED, not a control sitting there.
//
// ⚠ A still of a synth panel tells a viewer nothing: they cannot tell a knob
// they are being shown from a knob that is doing something. Every panel the
// film puts on screen is now a SEQUENCE — the same crop, the same panel, the
// value stepping — so the change is the thing you watch. shortsmith cycles a
// stage's `shots` at its `cut`, so N stills at a short cut IS the animation.
//
//   DAWPRO_PROFILE_ROOT=$PWD/out/profile DAW_CONTROL_PORT=17695 \
//   .build/debug/DAWApp &
//   DAW_CONTROL_PORT=17695 node sweepshot.mjs [scenario...]
//
// Scenarios: waveforms · cutoff · drive · vowel   (default: all four)
import { open, cmd, shot, close, SHOTS } from "./build.mjs";

const want = process.argv.slice(2);
const run = (name) => want.length === 0 || want.includes(name);

await open();

async function freshSynth(trackName, instrument) {
  await cmd("project.new", { discardChanges: true });
  const t = await cmd("track.add", { kind: "instrument", name: trackName });
  const id = t.id || t.track?.id;
  await cmd("track.setInstrument", { trackId: id, kind: "polySynth", ...instrument });
  await cmd("debug.synthEditor", { open: true, trackId: id });
  return id;
}

// ⚠ A SETTER'S RETURN IS NOT PROOF IT TOOK — read the value back off the
// project before spending a frame on it. A panel photographed a beat too early
// shows the PREVIOUS value, and every gate in this rig would pass that.
async function readBack(id, field) {
  // ⚠ project.overview reports `instrument` as a bare STRING ("polySynth") --
  // there are no params on it, so reading t.instrument[field] silently yields
  // undefined FOREVER and looks like a broken setter. Params live in the
  // snapshot. A read-back that can only print undefined is worse than none.
  const sn = await cmd("project.snapshot", {});
  const t = (sn.tracks || sn.project?.tracks || []).find((x) => x.id === id);
  const inst = t?.instrument;
  return typeof inst === "object" ? inst?.[field] ?? inst?.polySynth?.[field] : inst;
}

// 1. The constraint itself: the four buttons, each one lit in turn.
if (run("waveforms")) {
  const id = await freshSynth("Bass", {
    waveform: "saw", attack: 0.004, decay: 0.22, sustain: 0.55,
    release: 0.12, cutoffHz: 900, resonance: 0.28, gain: 0.55 });
  for (const w of ["saw", "square", "triangle", "sine"]) {
    await cmd("track.setInstrument", { trackId: id, kind: "polySynth", waveform: w });
    console.log("  waveform ->", w, "read back:", await readBack(id, "waveform"));
    await shot(`sweep-wave-${w}`);
  }
}

// 2. Thunder: the low-pass closing. This is the chapter's whole claim, so the
//    knob had better be seen moving through the numbers the narration says.
if (run("cutoff")) {
  const id = await freshSynth("Thunder", {
    waveform: "saw", attack: 0.002, decay: 2.2, sustain: 0.25,
    release: 1.4, cutoffHz: 16000, resonance: 0.35, gain: 0.5 });
  for (const hz of [16000, 6000, 1800, 480, 70]) {
    await cmd("track.setInstrument", { trackId: id, kind: "polySynth", cutoffHz: hz });
    console.log("  cutoff ->", hz, "read back:", await readBack(id, "cutoffHz"));
    await shot(`sweep-cutoff-${hz}`);
  }
}

// 3. The 808: drive at the three figures the film measures.
if (run("drive")) {
  await cmd("project.new", { discardChanges: true });
  const t = await cmd("track.add", { kind: "instrument", name: "808 sub" });
  const id = t.id || t.track?.id;
  await cmd("track.setInstrument", { trackId: id, kind: "polySynth",
    waveform: "sine", attack: 0.002, decay: 1.6, sustain: 0.0, release: 1.2,
    cutoffHz: 700, resonance: 0.0, gain: 0.8 });
  const fx = await cmd("fx.add", { trackId: id, kind: "saturator",
    params: { driveDb: 0, mix: 1.0, outputDb: 0 } });
  const eid = fx.effectId || fx.id;
  await cmd("debug.effectEditor", { open: true, trackId: id, effectId: eid });
  for (const db of [0, 14, 32]) {
    // ⚠ THE WIRE TAKES `name`. The MCP tool calls the same field `param`.
    await cmd("fx.setParam", { trackId: id, effectId: eid, name: "driveDb", value: db });
    const ov = await cmd("project.overview", {});
    const got = ov.tracks.find((x) => x.id === id)?.fx?.[0]?.params?.driveDb;
    console.log("  drive ->", db, "read back:", got);
    await shot(`sweep-drive-${db}`);
  }
}

// 4. The vowel: two EQ peaks walking from ee to ah to oo.
if (run("vowel")) {
  await cmd("project.new", { discardChanges: true });
  const t = await cmd("track.add", { kind: "instrument", name: "Voice" });
  const id = t.id || t.track?.id;
  await cmd("track.setInstrument", { trackId: id, kind: "polySynth",
    waveform: "saw", attack: 0.05, decay: 0.3, sustain: 0.8, release: 0.2,
    cutoffHz: 4000, resonance: 0.1, gain: 0.5 });
  // ⚠ THE EQ'S BANDS ARE `peak1`/`peak2`, NOT `band1`/`band2`. fx.add refuses
  // an unknown key and lists the real ones, which is the good case.
  const fx = await cmd("fx.add", { trackId: id, kind: "eq", params: {
    peak1Enabled: 1, peak1Freq: 270, peak1GainDb: 18, peak1Q: 8,
    peak2Enabled: 1, peak2Freq: 2290, peak2GainDb: 14, peak2Q: 8 } });
  const eid = fx.effectId || fx.id;
  await cmd("debug.effectEditor", { open: true, trackId: id, effectId: eid });
  for (const [v, f1, f2] of [["ee", 270, 2290], ["ah", 730, 1090], ["oo", 300, 870]]) {
    for (const [k, val] of [["peak1Freq", f1], ["peak2Freq", f2]])
      await cmd("fx.setParam", { trackId: id, effectId: eid, name: k, value: val });
    const ov = await cmd("project.overview", {});
    const p = ov.tracks.find((x) => x.id === id)?.fx?.[0]?.params;
    console.log(`  ${v} -> ${f1}/${f2}  read back: ${p?.peak1Freq}/${p?.peak2Freq}`);
    await shot(`sweep-vowel-${v}`);
  }
}

console.log("shots in", SHOTS);
await close();
