import puppeteer from 'puppeteer'; import fs from 'fs'; import path from 'path';
const HERE='/Users/dsemenov/Views/daw-pro/scripts/video/shorts/roads/lib';
const br=await puppeteer.launch({headless:'shell',args:['--use-angle=metal','--no-sandbox','--allow-file-access-from-files']});
for (const f of process.argv.slice(2)) {
  const P=JSON.parse(fs.readFileSync(f,'utf8'));
  const pg=await br.newPage(); await pg.setViewport({width:P.width,height:P.height});
  await pg.goto('file://'+path.join(HERE,'road.html'),{waitUntil:'networkidle0'});
  await pg.evaluate(p=>window.__init(p),P);
  await pg.waitForFunction('window.__ready || window.__err',{timeout:60000});
  const b=await pg.evaluate(()=>window.__paperBounds());
  console.log(f.split('/').pop(), 'repeat='+b.repeat, 'texH='+b.texH, 'texW='+b.texW,
    'vLo='+b.vLo, 'vHi='+b.vHi, 'zAtVLo='+b.zAtVLo, 'zAtVHi='+b.zAtVHi, 'bounds='+b.bounds.length,
    'md5ish='+JSON.stringify(b).length);
  console.log('   FULL '+JSON.stringify(b));
  await pg.close();
}
await br.close();
