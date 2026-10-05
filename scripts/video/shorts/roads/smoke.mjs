import puppeteer from 'puppeteer';
const b = await puppeteer.launch({headless:'shell',
  args:['--use-angle=metal','--no-sandbox','--allow-file-access-from-files']});
const pg = await b.newPage();
pg.on('pageerror', e => console.log('PAGE ERROR:', e.message));
pg.on('console', m => console.log('console:', m.text()));
await pg.setViewport({width:540, height:960});
await pg.goto('file://' + process.cwd() + '/smoke.html', {waitUntil:'networkidle0'});
const st = await pg.evaluate(() => ({done: !!window.__done, err: window.__err || null}));
console.log('render state:', JSON.stringify(st));
if (st.done) { await pg.screenshot({path: process.argv[2]}); console.log('screenshot written'); }
await b.close();
