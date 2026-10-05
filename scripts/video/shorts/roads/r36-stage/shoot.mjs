// ROUND 36 — deterministic frame driver: puppeteer + stage.html -> a directory of PNGs.
//
// ⚠ NO WALL CLOCK. One __frame(t) call per output frame at a fixed dt, then a
// screenshot. requestAnimationFrame against real time would drop frames under
// load and slide the light off the beat with nothing reporting it.
// ⚠ ALWAYS read back __err and a completion flag. A silent hang in the frame
// loop otherwise looks exactly like a slow render.
import puppeteer from 'puppeteer';
import fs from 'node:fs';
import path from 'node:path';

const payloadPath = path.resolve(process.argv[2]);
const outDir = path.resolve(process.argv[3]);
const seconds = parseFloat(process.argv[4]);
const stills = process.argv[5] ? process.argv[5].split(',').map(Number) : null;
// ⚠ THE VIEWPORT MUST FOLLOW THE PAYLOAD. Hardcoding 1080x1920 here while
// road.html sized itself from `P` would screenshot a 1920x1080 render through a
// portrait viewport -- a valid PNG of the wrong thing, which is the failure
// mode this whole project keeps meeting.
const FPS = 30;
const HERE = path.dirname(new URL(import.meta.url).pathname);

const payload = JSON.parse(fs.readFileSync(payloadPath, 'utf8'));
const W = payload.width ?? 1080, H = payload.height ?? 1920;
fs.mkdirSync(outDir, { recursive: true });

const b = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files',
         '--enable-gpu-rasterization', '--ignore-gpu-blocklist'] });
const pg = await b.newPage();
let pageErr = null;
pg.on('pageerror', e => { pageErr = e.message; console.error('PAGE ERROR:', e.message); });
pg.on('console', m => { if (m.type() === 'error') console.error('console:', m.text()); });
await pg.setViewport({ width: W, height: H, deviceScaleFactor: 1 });
await pg.goto('file://' + path.join(HERE, 'stage.html'), { waitUntil: 'networkidle0' });

const gl = await pg.evaluate(() => {
  const c = document.createElement('canvas').getContext('webgl2');
  const d = c.getExtension('WEBGL_debug_renderer_info');
  return { renderer: d ? c.getParameter(d.UNMASKED_RENDERER_WEBGL) : 'unknown' };
});
console.error('WebGL renderer:', gl.renderer);
if (/swiftshader|software/i.test(gl.renderer))
  console.error('⚠ SOFTWARE RENDERER — this is not the GPU path.');

await pg.evaluate(p => window.__init(p), payload);
const st0 = await pg.evaluate(() => ({ ready: !!window.__ready, err: window.__err || null }));
if (!st0.ready) { console.error('INIT FAILED:', st0.err || pageErr); await b.close(); process.exit(1); }

// ⭐ ROUND 35: an optional WINDOW START, so a comparison clip can begin part way
// into a piece. `START` absent = 0 = every existing caller's behaviour, byte for
// byte — the frame times are literally the same numbers.
const START = Number(process.env.START ?? 0);
const times = stills ? stills : Array.from({ length: Math.round(seconds * FPS) }, (_, i) => START + i / FPS);
const t0 = Date.now();
for (let i = 0; i < times.length; i++) {
  const t = times[i];
  await pg.evaluate(tt => window.__frame(tt), t);
  const st = await pg.evaluate(() => ({ t: window.__t, err: window.__err || null }));
  if (st.err) { console.error('FRAME ERROR at', t, ':', st.err); await b.close(); process.exit(1); }
  if (Math.abs(st.t - t) > 1e-9) { console.error(`FRAME CLOCK MISMATCH: asked ${t}, page says ${st.t}`); await b.close(); process.exit(1); }
  const name = stills ? `t${t.toFixed(2)}.png` : `f${String(i).padStart(6, '0')}.png`;
  await pg.screenshot({ path: path.join(outDir, name), optimizeForSpeed: true });
  if (!stills && i % 60 === 0)
    console.error(`  frame ${i}/${times.length}  ${((Date.now()-t0)/1000).toFixed(1)}s elapsed`);
}
console.error(`shoot: ${times.length} frames -> ${outDir} in ${((Date.now()-t0)/1000).toFixed(1)}s ` +
              `(${(times.length/((Date.now()-t0)/1000)).toFixed(1)} fps)`);
await b.close();
process.exit(0);
