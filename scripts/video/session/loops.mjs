// The DJ chapter: one four-bar loop, played over and over, with a new layer
// arriving on each pass. That IS the move -- a DJ does not change the loop,
// they change what is playing on top of it.
//
// Each pass is rendered separately with a different set of tracks unmuted, and
// the passes are concatenated afterwards. Rendering rather than recording is
// deliberate: it makes each layer's arrival EXACT, so the build is a fact
// about the arrangement rather than about my timing.
import { open, cmd, close } from "./build.mjs";
const AUD=process.env.SESSION_AUDIO || "./audio";
const PROJ="~/Music/DAW Pro Lessons/Session — Four Waveforms.dawproj";
await open();
await cmd("project.open",{path:PROJ});
const ov=await cmd("project.overview",{});
const id=Object.fromEntries(ov.tracks.map(t=>[t.name,t.id]));
// bar 33 is the drop; four bars there = beats 128..144 = 60.0s..67.5s at 128bpm
const LAYERS=[
  ["Kick","Kick click"],
  ["Kick","Kick click","Hats"],
  ["Kick","Kick click","Hats","Bass"],
  ["Kick","Kick click","Hats","Bass","808 sub","Stab"],
  ["Kick","Kick click","Hats","Bass","808 sub","Stab","Voice"],
];
for (let i=0;i<LAYERS.length;i++){
  const on=new Set(LAYERS[i]);
  for (const t of ov.tracks) await cmd("track.setMute",{trackId:t.id,muted:!on.has(t.name)});
  await cmd("render.mixdown",{path:`${AUD}/loop-${i}.wav`,fromBeat:128,durationSeconds:7.5});
  console.log(`pass ${i+1}: ${LAYERS[i].join(" + ")}`);
}
for (const t of ov.tracks) await cmd("track.setMute",{trackId:t.id,muted:false});
// prove the restore, rather than trusting the setter
const after=await cmd("project.overview",{});
console.log("still muted after restore:", after.tracks.filter(t=>t.muted).map(t=>t.name));
await close();
