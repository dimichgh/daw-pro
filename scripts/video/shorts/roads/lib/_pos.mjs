// Reconcile framing.mjs against the verifier: what does __screenPos say about
// EVERY voice (not just env>0.25) across a window?
import puppeteer from 'puppeteer';
import fs from 'node:fs'; import path from 'node:path';
const P = JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const HERE = '/Users/dsemenov/Views/daw-pro/scripts/video/shorts/roads/lib';
const W=P.width??1080, H=P.height??1920;
const t0=Number(process.argv[3]), t1=Number(process.argv[4]), step=Number(process.argv[5]||0.5);
const b=await puppeteer.launch({headless:'shell',args:['--use-angle=metal','--no-sandbox','--allow-file-access-from-files']});
const pg=await b.newPage(); await pg.setViewport({width:W,height:H,deviceScaleFactor:1});
await pg.goto('file://'+path.join(HERE,'road.html'),{waitUntil:'networkidle0'});
await pg.evaluate(p=>window.__init(p),P); await pg.waitForFunction('window.__ready || window.__err');
console.log(`W=${W} H=${H}  names=${JSON.stringify((P.voices||[]).map(v=>v.name||v.road))}`);
for(let t=t0;t<=t1+1e-9;t+=step){
  const pos=await pg.evaluate(tt=>window.__screenPos(tt),t);
  const s=pos.map(v=>v.live?`v${v.i}[env ${v.env.toFixed(3)} sx ${v.sx.toFixed(0)} sy ${v.sy.toFixed(0)} on=${v.onScreen?1:0}${v.env>0.25?'':' <FILTERED>'}]`:`v${v.i}[dead]`).join(' ');
  console.log(`t=${t.toFixed(3)} ${s}`);
}
await b.close();
