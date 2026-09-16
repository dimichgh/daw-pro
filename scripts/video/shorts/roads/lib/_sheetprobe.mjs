// ⛔⛔ READ THIS BEFORE BELIEVING A NUMBER FROM THIS PROBE. `stretch()` repeats
// the piece end to end but does NOT update `total`, `zFar`, `zlen`, `texH` or
// `paperRepeatV` — so at K>1 most of the notes sit PAST THE END OF THE ROAD and
// off the paper. That is fine for the question it was written for (does the
// per-frame JS cost grow with the NOTE COUNT) and WRONG for anything about the
// scene graph or the rendered picture: its "72 sheet children at 1x and 8x" is
// how I briefly concluded the scene was already bounded, and on the REAL long
// payload it is 72 -> 276. For scene/pixel/timing questions use lib/_shottime.mjs
// on a payload prep.mjs actually produced.
// scratch probe: what IS the sheet made of, and does it grow with N?
import puppeteer from 'puppeteer';
import fs from 'fs'; import path from 'path';
const HERE = path.dirname(new URL(import.meta.url).pathname);
const base = JSON.parse(fs.readFileSync(path.join(HERE,'../02-moonlight/out/payload.json'),'utf8'));
function stretch(P,K){const Q=JSON.parse(JSON.stringify(P));
 const span=Math.max(...P.voices.flatMap(v=>v.notes.map(n=>n.t+(n.dur||0))))+1.0;
 for(const v of Q.voices){const s=v.notes.slice();v.notes=[];for(let k=0;k<K;k++)for(const n of s)v.notes.push({...n,t:n.t+k*span});}
 if(Q.notes){const s=Q.notes.slice();Q.notes=[];for(let k=0;k<K;k++)for(const n of s)Q.notes.push({...n,t:n.t+k*span});}
 if(Q.onsets){const s=Q.onsets.slice();Q.onsets=[];for(let k=0;k<K;k++)for(const o of s)Q.onsets.push(o+k*span);}
 Q.__span=span*K;return Q;}
const br=await puppeteer.launch({headless:'shell',args:['--use-angle=metal','--no-sandbox','--allow-file-access-from-files']});
for(const K of [1,8]){
 const P=stretch(base,K); const pg=await br.newPage();
 await pg.goto('file://'+path.join(HERE,'road.html'),{waitUntil:'networkidle0'});
 await pg.evaluate(p=>window.__init(p),P);
 await pg.waitForFunction('window.__ready || window.__err',{timeout:60000});
 const r=await pg.evaluate(()=>{ window.__frame(5.0); return window.__stats(); });
 const tree=await pg.evaluate(()=>window.__tree ? window.__tree() : null);
 const m=await pg.metrics();
 console.log(`K=${K} notes=${P.voices.reduce((a,v)=>a+v.notes.length,0)} ` + JSON.stringify(r) + ` heapMB=${(m.JSHeapUsedSize/1e6).toFixed(1)}`);
 if(tree) console.log(JSON.stringify(tree,null,1));
 await pg.close();
}
await br.close();
