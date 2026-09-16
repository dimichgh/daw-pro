// THE TWO REMAINING ONE-FRAME EVENTS, LOCATED THEN MEASURED.
//  (a) a comet is dropped entirely when its distinct-sample count falls below 3
//      (`pts.length >= 3`), which happens once per voice per rest longer than
//      cometAge, and more often the longer the film;
//  (b) the live-voice count falling to 0 at the end.
// ⚠ LOCATING IS NOT MEASURING. A state transition is only a DEFECT if it moves
// pixels; the ribbon may already be sub-pixel when it is dropped. So this walks
// the film for the instants, then renders n-1/n/n+1 at each and reports the
// whole-frame mean |delta| against the film's own local baseline.
import puppeteer from 'puppeteer';
import fs from 'node:fs'; import path from 'node:path';
import { execFileSync } from 'node:child_process';
const PY='/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python';
const P=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
// CONTROL: --control raises the comet's minimum-point threshold so comets are
// dropped while still LONG. That IS a one-frame disappearance, and if the numbers
// below do not move for it then this probe cannot see one and its verdict on the
// real film is worth nothing.
const CTRL = process.argv.includes('--control');
const BLANK = Number(process.env.EVENTS_BLANK_AT ?? 60);
if (CTRL) { P.look = Object.assign({}, P.look, {cometBlankAt: BLANK});
  console.log(`  [control] every comet blanked for ONE FRAME at t=${BLANK}, in mid-passage`); }
const HERE=path.dirname(new URL(import.meta.url).pathname);
const RSEC=P.pictureSeconds ?? P.renderSeconds ?? ((P.total??14)+2);
const br=await puppeteer.launch({headless:'shell',args:['--use-angle=metal','--no-sandbox','--allow-file-access-from-files']});
const pg=await br.newPage(); await pg.setViewport({width:P.width,height:P.height,deviceScaleFactor:1});
await pg.goto('file://'+path.join(HERE,'road.html'),{waitUntil:'networkidle0'});
await pg.evaluate(p=>window.__init(p),P);
await pg.waitForFunction('window.__ready || window.__err',{timeout:120000});

const found = await pg.evaluate((rsec)=>{
  const NF=Math.round(rsec*30);
  const drops=[], liveDrops=[];
  let prevC=new Map(), prevLive=null;
  for(let i=0;i<NF;i++){
    const t=i/30; const S=window.__perf(t);
    const now=new Map();
    for(const c of S.comets) now.set(c.vi, c.pts.length);
    for(const [vi,n] of prevC) if(!now.has(vi)) drops.push({t:+t.toFixed(4), vi, wasPts:n});
    const live=S.voices.filter(v=>v.live).length;
    if(prevLive!==null && live<prevLive) liveDrops.push({t:+t.toFixed(4), from:prevLive, to:live});
    prevC=now; prevLive=live;
  }
  return {drops, liveDrops};
}, RSEC);
console.log(`(a) comet DROPPED (fell out of S.comets) ${found.drops.length} times`);
console.log('    ' + found.drops.slice(0,10).map(d=>`t=${d.t} v${d.vi} pts=${d.wasPts}`).join('  '));
console.log(`(b) live-voice count FELL ${found.liveDrops.length} times; last few: `
  + found.liveDrops.slice(-4).map(d=>`t=${d.t} ${d.from}->${d.to}`).join('  '));

const shot = async (t, f) => { await pg.evaluate(tt=>window.__frame(tt), t); await pg.screenshot({path:f}); };
const diff=(a,b)=>JSON.parse(execFileSync(PY,['-c',`
import sys,numpy as np
from PIL import Image
a=np.asarray(Image.open(sys.argv[1]).convert('RGB'),dtype=np.int16)
b=np.asarray(Image.open(sys.argv[2]).convert('RGB'),dtype=np.int16)
d=np.abs(a-b).max(axis=2)
import json;print(json.dumps({"mean":float(d.mean()),"n8":int((d>=8).sum())}))`,a,b],{encoding:'utf8'}));

const targets = [];
if (CTRL) targets.push({label:'CONTROL: all comets blanked 1 frame', t: BLANK});
for (const d of found.drops.slice(0, 4)) targets.push({label:`(a) comet drop v${d.vi} pts ${d.wasPts}`, t:d.t});
const lastLive = found.liveDrops.filter(d=>d.to===0).pop() || found.liveDrops[found.liveDrops.length-1];
if (lastLive) targets.push({label:`(b) live ${lastLive.from}->${lastLive.to}`, t:lastLive.t});
console.log('\n  the STEP at each, against the two frames either side of it:');
console.log('  event                                 t        step mean/255   px>=8    baseline mean   ratio');
for (const g of targets) {
  const n = Math.round(g.t*30);
  await shot((n-2)/30,'/tmp/ev_a.png'); await shot((n-1)/30,'/tmp/ev_b.png'); await shot(n/30,'/tmp/ev_c.png');
  const step = diff('/tmp/ev_b.png','/tmp/ev_c.png');
  const base = diff('/tmp/ev_a.png','/tmp/ev_b.png');
  const r = base.mean>0 ? (step.mean/base.mean).toFixed(2)+'x' : 'inf';
  console.log(`  ${g.label.padEnd(36)} ${g.t.toFixed(3).padStart(8)}  ${step.mean.toFixed(4).padStart(12)} ${String(step.n8).padStart(7)}  ${base.mean.toFixed(4).padStart(13)}   ${r.padStart(7)}`);
}
await br.close();
