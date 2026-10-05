import { connect, send, close } from "/Users/dsemenov/Views/daw-pro/claude-plugin/skills/ui-capture/scripts/dawctl.mjs";
import path from "node:path";
const OUT = `${process.env.FEATURES_HOME
  || new URL(".", import.meta.url).pathname.replace(/\/$/, "")}/out/deq`;
await connect("ws://127.0.0.1:17695");
const cmd = async (m,p={}) => { const r = await send(m,p); return r && r.result!==undefined ? r.result : r; };
async function render(label, cfg) {
  await cmd("project.new",{discardChanges:true});
  await cmd("transport.setTempo",{bpm:128});
  const t = await cmd("track.add",{kind:"instrument",name:"Bass"});
  const id = t.id || t.track?.id;
  await cmd("track.setInstrument",{trackId:id,kind:"polySynth",waveform:"saw",
    cutoffHz:900,resonance:0.18,attack:0.004,decay:0.12,sustain:0.55,release:0.09,gain:0.85});
  const notes=[];
  for (let bar=0; bar<8; bar++){ const root=[33,29,36,31][bar%4];
    notes.push({startBeat:bar*4,pitch:root,lengthBeats:0.45,velocity:112});
    for (const off of [0.5,1.5,2.5,3.5]) notes.push({startBeat:bar*4+off,pitch:root,lengthBeats:0.45,velocity:100}); }
  await cmd("clip.addMIDI",{trackId:id,atBeat:0,lengthBeats:32,notes});
  const eid = (await cmd("fx.add",{trackId:id,kind:"dynamicEQ"})).effectId;
  for (const [name,value] of Object.entries(cfg))
    await cmd("fx.setParam",{trackId:id,effectId:eid,name,value});
  const wav = path.resolve(`${OUT}/${label}.wav`);
  await cmd("render.mixdown",{path:wav,durationSeconds:17});
  return wav;
}
for (const th of [-34, -42, -50]) {
  await render(`th${Math.abs(th)}`, { band1Mode:1, band1Freq:90, band1Q:2,
    band1ThresholdDb:th, band1RangeDb:-9, band1Ratio:4, band1AttackMs:8, band1ReleaseMs:120 });
  console.log(`rendered th${Math.abs(th)}`);
}
close(); process.exit(0);
