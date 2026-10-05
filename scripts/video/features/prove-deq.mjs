// PROVE THE DYNAMIC EQ ACTUALLY MOVES AIR.
// band1Mode defaulted to 0 = OFF = "the band's filter is not even run", so the
// film's Dynamic EQ was a bit-exact bypass while its card photographed fine.
// This renders the SAME bass part three ways and compares the level INSIDE the
// band it is supposed to be controlling. A setter's return is not proof.
import { connect, send, close } from "/Users/dsemenov/Views/daw-pro/claude-plugin/skills/ui-capture/scripts/dawctl.mjs";
import path from "node:path";
const OUT = `${process.env.FEATURES_HOME
  || new URL(".", import.meta.url).pathname.replace(/\/$/, "")}/out/deq`;
await connect("ws://127.0.0.1:17695");
const cmd = async (m,p={}) => { const r = await send(m,p); return r && r.result!==undefined ? r.result : r; };

async function render(label, configure) {
  await cmd("project.new",{discardChanges:true});
  await cmd("transport.setTempo",{bpm:128});
  const t = await cmd("track.add",{kind:"instrument",name:"Bass"});
  const id = t.id || t.track?.id;
  await cmd("track.setInstrument",{trackId:id,kind:"polySynth",waveform:"saw",
    cutoffHz:900,resonance:0.18,attack:0.004,decay:0.12,sustain:0.55,release:0.09,gain:0.85});
  // 8 bars of the film's own bass line, loud enough to cross the -22 dB threshold
  const notes=[];
  for (let bar=0; bar<8; bar++){ const root=[33,29,36,31][bar%4];
    notes.push({startBeat:bar*4,pitch:root,lengthBeats:0.45,velocity:112});
    for (const off of [0.5,1.5,2.5,3.5]) notes.push({startBeat:bar*4+off,pitch:root,lengthBeats:0.45,velocity:100}); }
  await cmd("clip.addMIDI",{trackId:id,atBeat:0,lengthBeats:32,notes});
  const eid = (await cmd("fx.add",{trackId:id,kind:"dynamicEQ"})).effectId;
  for (const [name,value] of Object.entries(configure))
    await cmd("fx.setParam",{trackId:id,effectId:eid,name,value});
  const wav = path.resolve(`${OUT}/${label}.wav`);
  await cmd("render.mixdown",{path:wav,durationSeconds:17});
  return wav;
}

const OFF = await render("off", {});                                  // defaults: mode 0
const ON  = await render("on",  { band1Mode:1, band1Freq:90, band1ThresholdDb:-22,
                                  band1RangeDb:-5, band1Ratio:3 });
const KNOBS_ONLY = await render("knobs-only", { band1Freq:90, band1ThresholdDb:-22,
                                  band1RangeDb:-5, band1Ratio:3 });    // the OLD, BROKEN call
console.log(JSON.stringify({off:OFF,on:ON,knobsOnly:KNOBS_ONLY}));
close(); process.exit(0);
