// STILLS == SEQUENCE at an arbitrary t, without shooting the whole film.
// framegate.py can only test frames a shoot has already written, so the late
// segments of a 3-minute journey (the bow transitions at t=96 and t=134) are out
// of its reach without ~10 GB of PNGs. This does the same comparison: play the
// clock forward from 0 with NO screenshots, grab the frame; then, in a FRESH
// page, jump straight to the same t and grab it again. They must match, and each
// must differ from the NEXT frame by much more (the control).
import puppeteer from 'puppeteer';
import fs from 'node:fs'; import path from 'node:path';
import { execFileSync } from 'node:child_process';
const PY='/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python';
const P=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const HERE=path.dirname(new URL(import.meta.url).pathname);
const TS=process.argv.slice(3).map(Number);
const W=P.width,H=P.height, FPS=30;
async function shot(mode,t,out){
  const br=await puppeteer.launch({headless:'shell',args:['--use-angle=metal','--no-sandbox','--allow-file-access-from-files']});
  const pg=await br.newPage(); await pg.setViewport({width:W,height:H,deviceScaleFactor:1});
  await pg.goto('file://'+path.join(HERE,'road.html'),{waitUntil:'networkidle0'});
  await pg.evaluate(p=>window.__init(p),P);
  await pg.waitForFunction('window.__ready || window.__err',{timeout:60000});
  if(mode==='warm') await pg.evaluate((tt,fps)=>{for(let n=0;n<=Math.round(tt*fps);n++)window.__frame(n/fps);},t,FPS);
  else { await pg.evaluate(()=>window.__frame(0)); await pg.evaluate(tt=>window.__frame(tt),t); }
  await pg.screenshot({path:out});
  await br.close();
}
const diff=(a,b)=>JSON.parse(execFileSync(PY,['-c',`
import sys,numpy as np
from PIL import Image
a=np.asarray(Image.open(sys.argv[1]).convert('RGB'),dtype=np.int16)
b=np.asarray(Image.open(sys.argv[2]).convert('RGB'),dtype=np.int16)
d=np.abs(a-b).max(axis=2)
import json;print(json.dumps({"mean":float(d.mean()),"max":int(d.max())}))`,a,b],{encoding:'utf8'}));
for(const t of TS){
  const nx=Math.round(t*FPS+1)/FPS;
  await shot('warm',t,'/tmp/sq_w.png');
  await shot('cold',t,'/tmp/sq_c.png');
  await shot('warm',nx,'/tmp/sq_n.png');
  const own=diff('/tmp/sq_w.png','/tmp/sq_c.png'), nxt=diff('/tmp/sq_w.png','/tmp/sq_n.png');
  const ratio = own.mean>0 ? (nxt.mean/own.mean).toFixed(1)+'x' : 'inf';
  console.log(`t=${t.toFixed(4)}  cold-vs-sequence ${own.mean.toFixed(3)}/255 (max ${own.max})   sequence-vs-NEXT ${nxt.mean.toFixed(3)}/255   ratio ${ratio}  ${own.mean<0.05?'MATCHES':'*** DIFFERS ***'}`);
}
