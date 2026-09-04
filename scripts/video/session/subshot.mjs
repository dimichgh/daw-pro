// Shoot the 808 sub's POLY SYNTH panel on SINE -- the honest "before" half of
// the saturator A/B. The old before-shot was the SATURATOR at 32 dB, which
// contradicted the narration saying "here is a clean sine".
import { open, cmd, shot, close, SHOTS } from "./build.mjs";
await open();
await cmd("project.new", { discardChanges: true });
const t = await cmd("track.add", { kind: "instrument", name: "808 sub" });
const id = t.id || t.track?.id;
await cmd("track.setInstrument", { trackId: id, kind: "polySynth",
  waveform: "sine", attack: 0.001, decay: 0.6, sustain: 0.0, release: 0.15,
  cutoffHz: 200, resonance: 0 });
const ov = await cmd("project.overview", {});
console.log("READ BACK:", JSON.stringify(ov.tracks.find(x => x.id === id)).slice(0, 400));
await cmd("debug.synthEditor", { open: true, trackId: id });
await shot("synth-808-sine");
console.log("shot ->", `${SHOTS}/synth-808-sine.png`);
await close();
