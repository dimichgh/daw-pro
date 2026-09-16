// ROUND 36 — ON-SCREEN LIFE OF A ROD, under the clip's OWN camera plan.
// The claim being tested: an orbiting camera re-frames instead of leaving
// behind, so a rod's on-screen life should be its note's whole duration.
// Round 35 measured the road's version at 1.05 s of a 2.17 s note; this is the
// same question asked of the stage, and it is not allowed to be an argument.
import puppeteer from 'puppeteer';
import fs from 'node:fs'; import path from 'node:path';
const HERE = path.dirname(new URL(import.meta.url).pathname);
const P = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const br = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files'] });
const pg = await br.newPage();
await pg.setViewport({ width: P.width, height: P.height });
await pg.goto('file://' + path.join(HERE, 'stage.html'), { waitUntil: 'networkidle0' });
await pg.evaluate(p => window.__init(p), P);
await pg.waitForFunction('window.__ready || window.__err', { timeout: 60000 });
const acc = new Map();   // note index -> {on, frames}
const notes = P.notes;
const FPS = 30, T = P.total;
for (let f = 0; f < Math.round(T * FPS); f++) {
  const t = f / FPS;
  await pg.evaluate(tt => window.__frame(tt), t);
  const e = await pg.evaluate(() => { const x = window.__err || null; window.__err = null; return x; });
  if (e) { console.error('FRAME ERROR at', t, ':', e); process.exit(2); }
  const rs = await pg.evaluate(() => window.__rodScreen());
  const on = new Set(rs.filter(r => r.onScreen).map(r => r.i + ':' + r.k));
  const up = new Set(rs.map(r => r.i + ':' + r.k));
  notes.forEach((n, ni) => {
    if (t < n.t || t > n.t + n.dur) return;                 // only while SOUNDING
    const key = n.i + ':' + Math.max(0, n.slot ?? 0);
    let a = acc.get(ni); if (!a) { a = { on: 0, up: 0, tot: 0 }; acc.set(ni, a); }
    a.tot++; if (up.has(key)) a.up++; if (on.has(key)) a.on++;
  });
}
await br.close();
const byInst = new Map();
for (const [ni, a] of acc) {
  const n = notes[ni];
  let b = byInst.get(n.i); if (!b) { b = []; byInst.set(n.i, b); }
  b.push({ dur: n.dur, sounding: a.tot / FPS, up: a.up / FPS, on: a.on / FPS });
}
console.log(`camera: the clip's own plan, ${T}s, ${Math.round(T * FPS)} frames at ${FPS} fps`);
for (const [i, rows] of [...byInst].sort((a, b) => a[0] - b[0])) {
  const s = k => rows.reduce((x, r) => x + r[k], 0);
  const worst = rows.reduce((w, r) => (r.on / r.sounding < w.on / w.sounding ? r : w), rows[0]);
  console.log(`${P.instruments[i].name.padEnd(8)} notes=${String(rows.length).padStart(3)}  ` +
    `sounding total ${s('sounding').toFixed(2)}s  rod up ${s('up').toFixed(2)}s  ` +
    `ON SCREEN ${s('on').toFixed(2)}s  = ${(100 * s('on') / s('sounding')).toFixed(1)} % of the notes' own duration   ` +
    `worst single note ${(100 * worst.on / worst.sounding).toFixed(1)} % (dur ${worst.dur.toFixed(2)}s)`);
}
