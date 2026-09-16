import puppeteer from 'puppeteer';
import fs from 'node:fs'; import path from 'node:path';
const P = JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const HERE='/Users/dsemenov/Views/daw-pro/scripts/video/shorts/roads/lib';
const W=P.width,H=P.height;
const b=await puppeteer.launch({headless:'shell',args:['--use-angle=metal','--no-sandbox','--allow-file-access-from-files']});
const pg=await b.newPage(); await pg.setViewport({width:W,height:H,deviceScaleFactor:1});
await pg.goto('file://'+path.join(HERE,'road.html'),{waitUntil:'networkidle0'});
await pg.evaluate(p=>window.__init(p),P);
await pg.waitForFunction('window.__ready || window.__err',{timeout:30000});
for (const spec of process.argv.slice(3)) {
  const [a,z]=spec.split(':').map(Number);
  for (let t=a;t<=z;t+=0.2){
    const pos=await pg.evaluate(tt=>window.__screenPos(tt),t);
    const cam=await pg.evaluate(()=>({p:window.__camPos?window.__camPos():null}));
    const al=pos.filter(v=>v.live&&v.env>0.25);
    const bad=al.filter(v=>{const fx=v.sx/W,fy=v.sy/H;return !v.onScreen||fx<0.035||fx>0.965||fy<0.035||fy>0.965;});
    if(bad.length) console.log(t.toFixed(2), bad.map(v=>`v${v.i}(${(v.sx/W).toFixed(2)},${(v.sy/H).toFixed(2)}${v.onScreen?'':' BEHIND'})`).join(' '));
  }
  console.log('---');
}
await b.close();
