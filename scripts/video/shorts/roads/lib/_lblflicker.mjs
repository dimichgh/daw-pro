// ⚠ THE FAILURE A STILL CANNOT SHOW: a label whose on-screen reading direction is
// near-vertical has a near-zero x-delta, and if that delta crosses zero while the
// label is on screen the 'auto' rule flips it 180 degrees mid-shot — the round-7
// flicker. Walks CONSECUTIVE frames at 30 fps and counts per-label sign changes.
import puppeteer from 'puppeteer';
import fs from 'node:fs'; import path from 'node:path';
const P=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const A=Number(process.argv[3]), B=Number(process.argv[4]);
const HERE=path.dirname(new URL(import.meta.url).pathname);
const br=await puppeteer.launch({headless:'shell',args:['--use-angle=metal','--no-sandbox','--allow-file-access-from-files']});
const pg=await br.newPage(); await pg.setViewport({width:P.width,height:P.height});
await pg.goto('file://'+path.join(HERE,'road.html'),{waitUntil:'networkidle0'});
await pg.evaluate(p=>window.__init(p),P);
await pg.waitForFunction('window.__ready || window.__err',{timeout:60000});
let prev=new Map(), flips=[], seen=0, minAbs=1e9, minAt=null;
for(let n=Math.round(A*30); n<=Math.round(B*30); n++){
  const t=n/30;
  const r=await pg.evaluate(tt=>{window.__frame(tt);return window.__labelReading();},t);
  const now=new Map();
  for(const L of r){ seen++; now.set(L.i, L.d);
    if(Math.abs(L.d)<minAbs){minAbs=Math.abs(L.d);minAt={t:+t.toFixed(2),...L};}
    const p=prev.get(L.i);
    if(p!==undefined && Math.sign(p)!==Math.sign(L.d)) flips.push({t:+t.toFixed(3),i:L.i,from:p,to:L.d,sx:L.sx,sy:L.sy});
  }
  prev=now;
}
console.log(`window ${A}-${B}s  ${seen} on-screen label-frames  sign changes while on screen: ${flips.length}`);
console.log('  closest to zero: '+JSON.stringify(minAt));
if(flips.length) console.log('  first flips: '+JSON.stringify(flips.slice(0,8)));
await br.close();
process.exit(flips.length?1:0);
