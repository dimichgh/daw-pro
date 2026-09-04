// The hook was inaudible: the Voice layer arrived at +0.5 dB in its own band,
// which is not an arrival. Raise it, re-render, and MEASURE the same band
// again rather than assuming the fader did what the number says.
import { open, cmd, close } from "./build.mjs";
const AUD=process.env.SESSION_AUDIO || "./audio";
const PROJ="~/Music/DAW Pro Lessons/Session — Four Waveforms.dawproj";
await open();
await cmd("project.open",{path:PROJ});
const ov=await cmd("project.overview",{});
const voice=ov.tracks.find(t=>t.name==="Voice");
const stab =ov.tracks.find(t=>t.name==="Stab");
await cmd("track.setInstrument",{trackId:voice.id,kind:"polySynth",gain:0.75});
await cmd("track.setVolume",{trackId:voice.id,volume:1.7});
await cmd("track.setVolume",{trackId:stab.id,volume:0.8});   // make room for it
const back=await cmd("project.overview",{});
const v=back.tracks.find(t=>t.name==="Voice");
console.log("Voice volume read back:", v.volume);
await cmd("project.save",{path:PROJ});
// pass 5 again (all layers) and pass 4 (without voice) for the comparison
const ids=Object.fromEntries(back.tracks.map(t=>[t.name,t.id]));
const L4=["Kick","Kick click","Hats","Bass","808 sub","Stab"];
const L5=[...L4,"Voice"];
for (const [i,set] of [[3,L4],[4,L5]]) {
  const on=new Set(set);
  for (const t of back.tracks) await cmd("track.setMute",{trackId:t.id,muted:!on.has(t.name)});
  await cmd("render.mixdown",{path:`${AUD}/loop-${i}.wav`,fromBeat:128,durationSeconds:7.5});
  console.log("re-rendered pass", i+1);
}
for (const t of back.tracks) await cmd("track.setMute",{trackId:t.id,muted:false});
await cmd("render.mixdown",{path:`${AUD}/track-raw.wav`});
console.log("re-rendered the full track");
const fin=await cmd("project.overview",{});
console.log("muted after restore:", fin.tracks.filter(t=>t.muted).map(t=>t.name));
await cmd("project.save",{path:PROJ});
await close();
