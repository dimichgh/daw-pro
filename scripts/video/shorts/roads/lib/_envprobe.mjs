import puppeteer from 'puppeteer';
import fs from 'fs'; import path from 'path'; import { fileURLToPath } from 'url';
const HERE = path.dirname(fileURLToPath(import.meta.url));
const P = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
P.look = P.look || {};
for (const kv of process.argv.slice(5)) { const [k,v]=kv.split('='); P.look[k] = v==='true'?true:v==='false'?false:Number(v); }
const t0 = Number(process.argv[3]), t1 = Number(process.argv[4]);
const b = await puppeteer.launch({ headless:'shell', args:['--use-angle=metal','--no-sandbox','--allow-file-access-from-files'] });
const pg = await b.newPage(); await pg.setViewport({width:P.width,height:P.height});
await pg.goto('file://'+path.join(HERE,'road.html'), {waitUntil:'networkidle0'});
await pg.evaluate(p=>window.__init(p), P);
await pg.waitForFunction('window.__ready || window.__err');
const rows = await pg.evaluate((a,z)=>{ const o=[];
  for (let t=a; t<=z+1e-9; t+=1/30) { const S=window.__perf(t);
    o.push({t:+t.toFixed(3), v:S.voices.map(x=>({i:x.i,live:!!x.live,sp:!!x.spawning,env:x.live?+x.env.toFixed(4):0,y:x.live?+x.y.toFixed(3):null})),
            cm:(S.comets||[]).map(c=>({i:c.i,n:c.n??(c.pts?c.pts.length:undefined)}))}); }
  return o; }, t0, t1);
await b.close();
console.log(JSON.stringify(rows));
