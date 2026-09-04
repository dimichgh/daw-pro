// Is the saturator doing anything? Same note, three drive settings, measured.
import { open, cmd, addTrack, addClip, n, close } from "./build.mjs";
const AUD=process.env.SESSION_AUDIO || "./audio";
await open();
await cmd("project.new",{discardChanges:true});
await cmd("transport.setTempo",{bpm:120});
const id=await addTrack("808",{instrument:{kind:"polySynth",waveform:"sine",
  attack:0.002,decay:1.4,sustain:0.0,release:1.2,cutoffHz:900,resonance:0,gain:0.9}});
await addClip(id,0,8,[n(0,29,3,118)],"808");
const sat=await cmd("fx.add",{trackId:id,kind:"saturator"});
const satId=sat.effectId||(sat.effects&&sat.effects.at(-1).id);
for (const d of [0,14,32]) {
  const r1=await cmd("fx.setParam",{trackId:id,effectId:satId,name:"driveDb",value:d});
  const r2=await cmd("fx.setParam",{trackId:id,effectId:satId,name:"mix",value:1.0});
  if (r1 && r1.warnings && r1.warnings.length) console.log("  WARN drive:",r1.warnings);
  if (r2 && r2.warnings && r2.warnings.length) console.log("  WARN mix:",r2.warnings);
  await cmd("render.mixdown",{path:`${AUD}/sat-${d}.wav`,durationSeconds:4});
  console.log("rendered drive", d);
}
// and read the value back -- a setter's return is not proof it took
const d=await cmd("fx.describe",{trackId:id});
console.log("readback:", JSON.stringify(d).slice(0,300));
await close();
