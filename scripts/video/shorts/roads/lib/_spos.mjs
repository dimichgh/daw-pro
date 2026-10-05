// screen positions of named voices, per FRAME, for a payload — so a pixel probe
// can look where the light actually is instead of at a whole region.
import puppeteer from 'puppeteer';
import fs from 'fs'; import path from 'path'; import { fileURLToPath } from 'url';
const HERE = path.dirname(fileURLToPath(import.meta.url));
const P = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const f0 = Number(process.argv[3]), f1 = Number(process.argv[4]);
const vis = process.argv[5].split(',').map(Number);
const b = await puppeteer.launch({ headless:'shell', args:['--use-angle=metal','--no-sandbox','--allow-file-access-from-files'] });
const pg = await b.newPage(); await pg.setViewport({width:P.width,height:P.height});
await pg.goto('file://'+path.join(HERE,'road.html'), {waitUntil:'networkidle0'});
await pg.evaluate(p=>window.__init(p), P);
await pg.waitForFunction('window.__ready || window.__err');
const out = await pg.evaluate((a,z,VS)=>{ const o=[];
  for (let f=a; f<=z; f++) { const S=window.__screenPos(f/30);
    o.push({f, v: VS.map(i=>{ const v=S.find(x=>x.i===i);
      return v && v.live ? {i, sx:+v.sx.toFixed(1), sy:+v.sy.toFixed(1), on:!!v.onScreen, env:+v.env.toFixed(4)} : {i, live:false}; })}); }
  return o; }, f0, f1, vis);
await b.close();
fs.writeFileSync(process.argv[6], JSON.stringify(out));
console.log(process.argv[6]);
