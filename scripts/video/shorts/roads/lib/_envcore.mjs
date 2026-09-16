// env vs envCore for every voice — the lamp and the DISK fade independently
// (coreSteady blends them), so a severity call made on `env` alone is a guess.
import puppeteer from 'puppeteer';
import fs from 'node:fs'; import path from 'node:path';
const P=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const HERE=path.dirname(new URL(import.meta.url).pathname);
const t0=+process.argv[3], t1=+process.argv[4], st=+(process.argv[5]||0.5);
const b=await puppeteer.launch({headless:'shell',args:['--use-angle=metal','--no-sandbox','--allow-file-access-from-files']});
const pg=await b.newPage(); await pg.setViewport({width:P.width??1080,height:P.height??1920});
await pg.goto('file://'+path.join(HERE,'road.html'),{waitUntil:'networkidle0'});
await pg.evaluate(p=>window.__init(p),P); await pg.waitForFunction('window.__ready || window.__err');
console.log(`coreSteady=${P.look?.coreSteady ?? 0}  coreGain=${P.look?.coreGain ?? '?'}`);
for(let t=t0;t<=t1+1e-9;t+=st){
  const r=await pg.evaluate(tt=>{const S=window.__perf(tt);
    return S.voices.map(v=>({i:v.i,road:v.road,live:!!v.live,
      env:v.live?+v.env.toFixed(4):null, core:v.live&&v.envCore!==undefined?+v.envCore.toFixed(4):null}));},t);
  console.log(`t=${t.toFixed(3)} `+r.map(v=>v.live?`v${v.i}(${v.road}) env ${v.env} core ${v.core}`:`v${v.i} dead`).join('  '));
}
await b.close();
