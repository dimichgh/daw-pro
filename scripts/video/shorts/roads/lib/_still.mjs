// one frame at a named t, to a PNG. usage: node lib/_still.mjs <payload> <t> <out.png>
import puppeteer from 'puppeteer';
import fs from 'fs'; import path from 'path';
const HERE = path.dirname(new URL(import.meta.url).pathname);
const P = JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const T = Number(process.argv[3]); const OUT = process.argv[4];
const br=await puppeteer.launch({headless:'shell',args:['--use-angle=metal','--no-sandbox','--allow-file-access-from-files']});
const pg=await br.newPage();
await pg.setViewport({width:P.width??1920,height:P.height??1080});
await pg.goto('file://'+path.join(HERE,'road.html'),{waitUntil:'networkidle0'});
await pg.evaluate(p=>window.__init(p),P);
await pg.waitForFunction('window.__ready || window.__err',{timeout:60000});
const e=await pg.evaluate(()=>window.__err||null); if(e){console.log('[BROKEN] '+e);process.exit(2);}
await pg.evaluate(t=>window.__frame(t),T);
await pg.screenshot({path:OUT});
console.log(OUT+'  t='+T+'  '+JSON.stringify(await pg.evaluate(()=>window.__stats())));
await br.close();
