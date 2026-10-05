import puppeteer from 'puppeteer';
import fs from 'fs'; import path from 'path';
const HERE = path.dirname(new URL(import.meta.url).pathname);
const P = JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const br=await puppeteer.launch({headless:'shell',args:['--use-angle=metal','--no-sandbox','--allow-file-access-from-files']});
const pg=await br.newPage();
await pg.goto('file://'+path.join(HERE,'road.html'),{waitUntil:'networkidle0'});
await pg.evaluate(p=>window.__init(p),P);
await pg.waitForFunction('window.__ready || window.__err',{timeout:60000});
await pg.evaluate(()=>window.__frame(5.0));
const t=await pg.evaluate(()=>window.__tree());
const h={};
for(const o of t){const k=`${o.type} verts=${o.verts} inst=${o.instances} name=${o.name}`;h[k]=(h[k]||0)+1;}
console.log(process.argv[2]);
for(const [k,v] of Object.entries(h).sort((a,b)=>b[1]-a[1])) console.log(`  x${v}  ${k}`);
await br.close();
