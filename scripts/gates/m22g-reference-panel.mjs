// m22-g P3 gate — REFERENCE row + panel + debug.referenceSeed.
//
// CLASS 1 since m23-ac-3b-3: this gate builds the binary and launches its own
// staging app on 17695 (17600 is the user's LIVE app — never touched). It no
// longer measures whatever happened to be on the port; the gate that asserts the
// pixels now also owns the process that drew them.
//
// Usage: node scripts/gates/m22g-reference-panel.mjs
//        M22G_FIXTURE=/path/to/song.wav overrides the reference audio.
// Output: captures land under /tmp/daw-gate-out/m22g-p3/ — the very directory
// `startStaging({gate:"m22g-p3"})` derives, so the pidfile sits beside them.
// Promoted from the session scratchpad at the m22-g P3 close (2026-07-26).
import { createHash } from "node:crypto";
import { readFileSync, mkdirSync } from "node:fs";
import zlib from "node:zlib";
import { buildOrAbort, startStaging, stopStaging, connect, sleep } from "./_staging.mjs";

const GATE = "m22g-p3";                     // also names the pidfile + out dir
const OUT = `/tmp/daw-gate-out/${GATE}`;
mkdirSync(OUT, { recursive: true });
// A real audio file to import as the reference. Any stereo WAV works; the
// gate asserts the analysis SHAPE and the law, not specific loudness values
// (except A4b, which recomputes the −14 fallback from the file's own numbers).
const FIXTURE = process.env.M22G_FIXTURE
  ?? `${process.env.HOME}/Library/Application Support/DAWPro/References/orch-reference.wav`;

buildOrAbort({ label: "building staging binary (m22g)…" });
startStaging({ gate: GATE });
// The harness connect retries 40x1 s and refuses port 17600 outright. The local
// 20x1 s loop it replaced was written against an app a human had already
// launched; against our own cold boot it was the tighter budget of the two.
const ws = await connect();
let n = 0, pass = 0, fail = 0;
function cmd(command, params = {}, timeoutMs = 60000) {
  return new Promise((res, rej) => {
    const i = `m22g_${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), timeoutMs);
    const h = ev => {
      const m = JSON.parse(ev.data);
      if (m.id !== i) return;
      clearTimeout(t); ws.removeEventListener("message", h); res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id: i, command, params }));
  });
}
function check(name, ok, detail = "") {
  if (ok) { pass++; console.log(`PASS ${name}`); }
  else { fail++; console.log(`FAIL ${name} :: ${detail}`); }
}
/** A capture plus everything needed to convert points into image rows. */
async function captureFrame(tag) {
  const path = `${OUT}/${tag}.png`;
  const r = await cmd("debug.captureUI", { path });
  if (!r.ok) throw new Error("capture failed " + JSON.stringify(r));
  const buf = readFileSync(path);
  const sha = createHash("sha256").update(buf).digest("hex").slice(0, 12);
  console.log(`   capture ${tag}: ${r.result.width}x${r.result.height} sha ${sha}`);
  return { path, sha, ...r.result };
}
async function capture(tag) { return (await captureFrame(tag)).sha; }

// ══ PIXEL INSTRUMENTS — because a whole-window sha cannot say WHERE ═════════
//
// ⚠️ m23-be. Section E used to hash the WHOLE 2800×2000 window and assert the
// five shas differ. It was red on every run, and the reading it invited ("the
// chip stops distinguishing sign at ±24") was wrong in both directions: the
// match-gain readout was not in the frame AT ALL (see the framing note below),
// and the only pixels that moved across the five legs were 5–19 px of live
// chrome elsewhere in the window. A whole-window sha can go falsely GREEN on
// unrelated motion and falsely RED on none — it was never measuring the chip.
//
// So the legs now crop. `debug.explainFrames` gives the row's MEASURED rect and
// (m23-ag) the `captureOrigin`/`captureSize` that convert it into image rows;
// `zlib` is standard library and the captures are 8-bit non-interlaced RGBA.
// Same reader as m23an-header-feedback.mjs / m23a2-insert-slot-reserve.mjs.
function readPNG(path) {
  const d = readFileSync(path);
  let i = 8, idat = [], w = 0, h = 0, color = 6;
  while (i < d.length) {
    const ln = d.readUInt32BE(i), typ = d.toString("ascii", i + 4, i + 8);
    if (typ === "IHDR") {
      w = d.readUInt32BE(i + 8); h = d.readUInt32BE(i + 12);
      if (d[i + 16] !== 8 || d[i + 20] !== 0) throw new Error("unexpected PNG form");
      color = d[i + 17];
    } else if (typ === "IDAT") idat.push(d.subarray(i + 8, i + 8 + ln));
    else if (typ === "IEND") break;
    i += 12 + ln;
  }
  const bpp = { 0: 1, 2: 3, 4: 2, 6: 4 }[color];
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = w * bpp, out = Buffer.alloc(h * stride);
  let pos = 0;
  for (let y = 0; y < h; y++) {
    const f = raw[pos++], o = y * stride, p = o - stride;
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? out[o + x - bpp] : 0;
      const b = y ? out[p + x] : 0;
      const c = (y && x >= bpp) ? out[p + x - bpp] : 0;
      let v = raw[pos + x];
      if (f === 1) v += a;
      else if (f === 2) v += b;
      else if (f === 3) v += (a + b) >> 1;
      else if (f === 4) {
        const pp = a + b - c, pa = Math.abs(pp - a), pb = Math.abs(pp - b), pc = Math.abs(pp - c);
        v += (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
      } else if (f !== 0) throw new Error(`filter ${f}`);
      out[o + x] = v & 0xFF;
    }
    pos += stride;
  }
  return { w, h, bpp, data: out };
}
/** Bounding box of the pixels where two same-size frames differ, or null. */
function diffBox(pathA, pathB) {
  const A = readPNG(pathA), B = readPNG(pathB);
  if (A.w !== B.w || A.h !== B.h) throw new Error("frame size changed mid-gate");
  const stride = A.w * A.bpp;
  let minX = A.w, minY = A.h, maxX = -1, maxY = -1, n = 0;
  for (let y = 0; y < A.h; y++) {
    const o = y * stride;
    if (A.data.compare(B.data, o, o + stride, o, o + stride) === 0) continue;
    for (let x = 0; x < A.w; x++) {
      const p = o + x * A.bpp;
      if (A.data.compare(B.data, p, p + A.bpp, p, p + A.bpp) !== 0) {
        n++;
        if (x < minX) minX = x; if (x > maxX) maxX = x;
        if (y < minY) minY = y; if (y > maxY) maxY = y;
      }
    }
  }
  return maxY < 0 ? null : { minX, minY, maxX, maxY, n };
}
/** sha of ONE rectangle of a frame, in PIXELS. */
function cropSha(path, box) {
  const P = readPNG(path);
  const x0 = Math.max(0, box.x), y0 = Math.max(0, box.y);
  const x1 = Math.min(P.w, box.x + box.w), y1 = Math.min(P.h, box.y + box.h);
  if (x1 <= x0 || y1 <= y0) throw new Error(`crop box outside the frame: ${JSON.stringify(box)}`);
  const h = createHash("sha256");
  for (let y = y0; y < y1; y++) {
    const o = y * P.w * P.bpp;
    h.update(P.data.subarray(o + x0 * P.bpp, o + x1 * P.bpp));
  }
  return h.digest("hex").slice(0, 12);
}
const inside = (box, d) => d !== null && d.minX >= box.x && d.maxX < box.x + box.w
  && d.minY >= box.y && d.maxY < box.y + box.h;
const boxStr = (d) => (d ? `y=${d.minY}..${d.maxY} x=${d.minX}..${d.maxX} px=${d.n}` : "(no pixel moved)");

/**
 * The `.explainable` frames of the REFERENCE row + its A/B chip, with the
 * capture-space anchor. Explain mode is toggled ON only long enough to read the
 * frames (they flow only while it is active) and OFF again before any capture,
 * so the overlay never lands in a hashed frame.
 */
async function referenceRowFrames() {
  await cmd("debug.explainMode", { on: true });
  await sleep(300);
  const r = await cmd("debug.explainFrames", { ids: ["referenceRow", "referenceABToggle"] });
  await cmd("debug.explainMode", { on: false });
  await sleep(300);
  return r.result ?? {};
}

console.log("=== SECTION A — LIVE WIRE EXERCISE (real reference.* commands) ===");
await cmd("project.new", { discardChanges: true });
await cmd("debug.referenceSeed", { clear: true });
await cmd("ui.showMixer", { show: true });
// ⚠️ FRAMING — the strip legs below are worthless without it (m23-be).
//
// The master strip has ONE internal vertical scroller (m23-a) and its Pro
// anatomy — inserts, the automation lane, the fader, the dB readout, LOUDNESS,
// STEREO IMAGE, then the REFERENCE row — overflows the viewport at the staging
// window's 1400×1000 pt. The row is LAST, so it is what falls off: MEASURED,
// with the master insert chain expanded the row's frame lands at y 854..886 pt
// while the strip's `clipShape` cuts at ~863, so only the top ~9 pt of line 1
// rasterizes and line 2 — the A/B chip and the match-gain readout — is not
// drawn at all. Every strip capture in this gate was hashing a window the chip
// is not in; section E's five "chip width" legs measured nothing but live
// chrome elsewhere in the window.
//
// Collapsing the master insert chain is the fix with the fewest strings
// attached: it is the m23-a disclosure a user can toggle, staged through the
// seam m23-a built for exactly this, it keeps the console in PRO (the density
// with the most strip anatomy, so the tightest fit is still the one measured),
// and it is display-independent — `debug.windowFrame {height}` would make the
// gate's verdict depend on how tall the RUNNER's screen is. With the chain
// collapsed the strip's anatomy fits, the greedy fader absorbs the slack, and
// the row is pinned to the bottom of the viewport at y 826..858 pt.
//
// This is NOT assumed: E0/E2b below prove the readout actually rasterizes, in
// pixels, and fail loudly if a future block pushes the row off again.
//
// ⚠️ PIN, DON'T INHERIT. `panelDensity` and `panelLayout` are STICKY
// preferences — `UserDefaultsPanelLayoutBacking` writes them to the staging
// binary's own defaults domain (`DAWApp`, NOT the user's bundled
// `dev.dawpro.app`), so they survive the process and leak into the next gate.
// Measured during m23-be: this gate's UNMODIFIED source failed E2 for one
// runner and passed it for another, on nothing but a density a previous probe
// had left behind — and `PanelDensityStore`'s own default is SIMPLE, so a fresh
// machine would not even have run the density these comments are written for.
// Both are therefore SET here rather than read. The collapse flag is put back at
// the teardown; the density is not, because `debug.panelDensity` has no
// read-only form to learn the prior value from (a bare call refuses). PRO is the
// deliberate choice: it is the density with the most strip anatomy, so the
// tightest fit is the one measured.
const priorInsertsCollapsed =
  (await cmd("debug.panelLayout")).result?.mixerInsertsCollapsed ?? false;
// m23-du(a) CLOSED the read gap this comment used to describe. The density is
// now captured BEFORE it is overwritten, and restored alongside the collapse
// flag. ⚠️ Read `stored`, NEVER `mode`: `mode` is the EFFECTIVE density and says
// `simple` both for "explicitly simple" and for "never set", so writing it back
// would convert an unset key into an explicit one.
const priorMixerDensity = (await cmd("debug.panelDensity", { panel: "mixer" })).result?.stored ?? null;
console.log(`   prior mixer density: stored=${priorMixerDensity ?? "UNSET"}`);
await cmd("debug.panelDensity", { panel: "mixer", mode: "pro" });
await cmd("debug.panelLayout", { mixerInsertsCollapsed: true });

// ── m23-du(b): the restore must survive the THROW path, not just the happy one.
// The put-back at the bottom of this file is plain straight-line code. Every
// `cmd()` rejects on a 15 s TIMEOUT (:37) and `cropSha` throws when a crop box
// falls outside the frame, so ANY of those skipped the restore entirely and
// leaked `mixerInsertsCollapsed: true` into the next gate — the m23-ah-6 shape,
// where a hardening pass introduces a leak that did not exist before it.
//
// ⚠️ `process.on("exit")` CANNOT do this job: the restore is a WebSocket
// round-trip, and an exit handler may only run SYNCHRONOUS work, so the frame
// would never leave the socket. It has to be an async handler that awaits.
//
// ⚠️ Not a `try/finally` around the body either: that would re-indent ~360 lines
// of legs for one teardown line, and a diff that large across a gate whose
// verdict is pixel-calibrated is its own risk. Idempotent + handler-driven gets
// the same coverage with a local change.
let ambientRestored = false;
async function restoreAmbient(reason) {
  if (ambientRestored) return;          // idempotent: normal path AND handler may both call
  ambientRestored = true;
  try {
    await cmd("debug.panelLayout", { mixerInsertsCollapsed: priorInsertsCollapsed });
    // m23-du(a): the density too — this gate's HEADLINE leak. A null prior means
    // the panel was never set, and there is no clear verb yet, so the choice is
    // between leaving OUR `pro` behind and writing the app default explicitly.
    // `simple` is strictly better: a fresh machine's EFFECTIVE density is simple,
    // so this leaves the next gate behaving identically to a fresh machine and
    // differs only by a key existing. Leaving `pro` would change BEHAVIOUR, which
    // is the defect m23-du exists to fix. Never silent.
    const target = priorMixerDensity ?? "simple";
    await cmd("debug.panelDensity", { panel: "mixer", mode: target });
    console.log(`   ambient restored (${reason}): mixerInsertsCollapsed=${priorInsertsCollapsed}`
      + `, mixer density=${target}${priorMixerDensity ? "" : " (prior UNSET — wrote the app default; "
      + "only a clear verb, m23-du(a) still open, could restore true absence)"}`);
  } catch (e) {
    // Loud, never silent — a failed restore is exactly the condition that
    // poisons the NEXT gate, and it must not hide behind a red leg elsewhere.
    console.error(`   ⚠️ AMBIENT RESTORE FAILED (${reason}): ${e.message}`);
  }
}
for (const sig of ["unhandledRejection", "uncaughtException"]) {
  process.on(sig, async (err) => {
    console.error(`\n${sig.toUpperCase()} — restoring ambient state before exit:`, err);
    await restoreAmbient(sig);
    stopStaging(GATE);                  // idempotent; a missing pidfile is an early return
    process.exit(3);
  });
}

// A1 bare seed call is READ-ONLY (the m11-a law)
let r = await cmd("debug.referenceSeed");
check("A1 bare debug.referenceSeed is read-only",
  r.ok && r.result.seeded === false && r.result.panel === false && r.result.phase === "empty",
  JSON.stringify(r));

// A2 no reference on a fresh project; strip row ABSENT
r = await cmd("reference.status");
check("A2 fresh project has no reference", r.ok && !r.result.reference && r.result.monitoring === false,
  JSON.stringify(r));
const shaNoRow = await capture("A2-strip-row-absent");

// A3 live import of the fixture WAV
r = await cmd("reference.import", { path: FIXTURE, name: "Orch Reference" }, 180000);
check("A3 reference.import lands a slot WITH analysis",
  r.ok && r.result.name === "Orch Reference" && r.result.analysis
    && typeof r.result.analysis.integratedLufs === "number"
    && r.result.analysis.bandsDb.length === 24,
  JSON.stringify(r).slice(0, 400));
const refLufs = r.ok ? r.result.analysis.integratedLufs : null;
const refTP = r.ok ? r.result.analysis.truePeakDbtp : null;
console.log(`   reference integrated ${refLufs} LUFS, true peak ${refTP} dBTP, dur ${r.result?.analysis?.durationSeconds}`);

// A4 status now previews the match gain through the real law
r = await cmd("reference.status");
check("A4 status carries the slot + a wouldMatchGainDb preview",
  r.ok && r.result.reference && r.result.monitoring === false
    && typeof r.result.wouldMatchGainDb === "number"
    && r.result.matchGainDb === undefined,
  JSON.stringify(r).slice(0, 300));
const wouldGain = r.result.wouldMatchGainDb;
// No mix has played yet → fallback basis −14: gain = −14 − refLufs, TP-clamped.
const expectFallback = Math.min(-14 - refLufs, -1 - refTP);
check("A4b the preview equals the −14 fallback law, TP-clamped",
  Math.abs(wouldGain - expectFallback) < 1e-6,
  `got ${wouldGain} expected ${expectFallback}`);

// A5 the strip row is now PRESENT — a LIVE (unseeded) capture
const shaRow = await capture("A5-strip-row-present-live");
check("A5 the strip row changed the master strip's pixels", shaRow !== shaNoRow,
  `${shaRow} vs ${shaNoRow}`);

// A6 monitor ON through the real engine lane
r = await cmd("reference.setMonitor", { on: true });
check("A6 setMonitor on returns the match evidence",
  r.ok && r.result.monitoring === true && typeof r.result.matchGainDb === "number"
    && typeof r.result.matchBasis === "string",
  JSON.stringify(r));
console.log(`   monitoring gain ${r.result?.matchGainDb} basis ${r.result?.matchBasis} ceilingLimited ${r.result?.ceilingLimited}`);

// A7 offset + trim ride the real store methods
r = await cmd("reference.setOffset", { seconds: 0.3 });
check("A7 setOffset echoes the slot", r.ok && Math.abs(r.result.offsetSeconds - 0.3) < 1e-9, JSON.stringify(r).slice(0, 200));
r = await cmd("reference.setTrim", { db: -2.5 });
check("A7b setTrim echoes the slot + the re-applied gain while monitoring",
  r.ok && Math.abs(r.result.trimDb + 2.5) < 1e-9 && typeof r.result.matchGainDb === "number",
  JSON.stringify(r).slice(0, 260));

// A8 real audio through the master so the compare has a mix side
r = await cmd("debug.importAudio", { paths: [FIXTURE], atBeat: 0 }, 120000);
check("A8 fixture imported as a timeline clip", r.ok && r.result.results?.[0]?.clipId, JSON.stringify(r).slice(0, 260));
await cmd("reference.setMonitor", { on: false });   // hear the MIX so it meters
await cmd("transport.seek", { beats: 0 });
await cmd("transport.play");
await sleep(4000);

r = await cmd("reference.compare");
const d1 = r.result?.delta;
check("A9 compare returns mix + reference + deltas after real playback",
  r.ok && r.result.mix && r.result.reference && d1
    && typeof d1.lufs === "number" && Array.isArray(d1.bandsDb) && d1.bandsDb.length === 24,
  JSON.stringify(r).slice(0, 320));
console.log(`   Δlufs ${d1?.lufs?.toFixed(3)} Δtp ${d1?.truePeakDb?.toFixed(3)} Δwidth ${d1?.width?.toFixed(3)} Δcorr ${d1?.correlation?.toFixed(3)}`);
// delta = reference − mix, checked against the two sides it was built from
check("A9b Δlufs is exactly reference − mix",
  Math.abs(d1.lufs - (r.result.reference.integratedLufs - r.result.mix.integratedLufs)) < 1e-12,
  `${d1.lufs}`);

console.log("=== SECTION B — LIVE POLL PROOF (no seed, the m22-e law) ===");
// The panel opens on LIVE data. Nothing but the unpaused .periodic TimelineViews
// invalidates it, so two captures a few seconds apart must differ — and the
// compare numbers behind them must move too.
await cmd("debug.referenceSeed", { panel: true });
await sleep(700);
const liveA = await capture("B1-panel-live-t0");
const cA = (await cmd("reference.compare")).result;
await sleep(3000);
const liveB = await capture("B2-panel-live-t3");
const cB = (await cmd("reference.compare")).result;
check("B1 the live panel repainted between two captures (polls tick unfocused)",
  liveA !== liveB, `${liveA} == ${liveB}`);
check("B2 the live mix evidence itself moved",
  cA.mix.integratedLufs !== cB.mix.integratedLufs || cA.delta.lufs !== cB.delta.lufs,
  `${cA.mix.integratedLufs} / ${cB.mix.integratedLufs}`);
console.log(`   mix integrated t0 ${cA.mix.integratedLufs?.toFixed(3)} → t3 ${cB.mix.integratedLufs?.toFixed(3)}`);
await cmd("transport.stop");

console.log("=== SECTION C — SEEDED PIXEL LEGS ===");
await cmd("debug.referenceSeed", { panel: false });

// C1 EMPTY panel
r = await cmd("debug.referenceSeed", { slot: false, panel: true });
check("C1 empty state staged", r.ok && r.result.phase === "empty" && r.result.panel === true, JSON.stringify(r));
const shaEmpty = await capture("C1-panel-empty");

// C2 LOADED + MONITORING (cyan REF lit, match gain, both curves, deltas)
r = await cmd("debug.referenceSeed", {
  slot: true, name: "Blue Monday (master)", monitoring: true,
  matchGainDb: -6.2, matchBasis: "liveIntegrated", ceilingLimited: false,
  mix: true, mixLufs: -12.8, mixTruePeakDbtp: -2.4, mixLra: 7.6, panel: true,
});
check("C2 loaded+monitoring staged",
  r.ok && r.result.phase === "ready" && r.result.monitoring === true
    && r.result.matchGainDb === -6.2 && r.result.mixBands === true
    && r.result.mixIntegratedLufs === -12.8,
  JSON.stringify(r));
await sleep(900);   // let the mix average seed + a couple of poll frames land
const shaMonitoring = await capture("C2-panel-loaded-monitoring");
check("C2b the monitoring panel differs from the empty one", shaMonitoring !== shaEmpty);

// C3 ceilingLimited → amber
r = await cmd("debug.referenceSeed", { ceilingLimited: true, matchGainDb: 1.4, monitoring: true, panel: true });
check("C3 ceiling-limited staged", r.ok && r.result.ceilingLimited === true && r.result.matchGainDb === 1.4, JSON.stringify(r));
await sleep(500);
const shaCeiling = await capture("C3-panel-ceiling-limited-amber");
check("C3b amber clamp state repaints the panel", shaCeiling !== shaMonitoring);

// C4 fileMissing
r = await cmd("debug.referenceSeed", { fileMissing: true, panel: true });
check("C4 file-missing staged", r.ok && r.result.phase === "fileMissing" && r.result.fileMissing === true, JSON.stringify(r));
const shaMissing = await capture("C4-panel-file-missing");
check("C4b file-missing repaints", shaMissing !== shaCeiling);
await cmd("debug.referenceSeed", { fileMissing: false });

// C5 no mix evidence → honest dashes in the delta row
r = await cmd("debug.referenceSeed", { mix: false, monitoring: false, panel: true });
check("C5 no-mix-evidence staged", r.ok && r.result.mixIntegratedLufs === null && r.result.mixBands === false, JSON.stringify(r));
await sleep(500);
const shaNoMix = await capture("C5-panel-no-mix-evidence-dashes");

// C6 strip row ABSENT under a seeded no-slot, PRESENT with one — panel closed
await cmd("debug.referenceSeed", { slot: false, panel: false });
const shaSeedNoRow = await capture("C6-strip-row-absent-seeded");
await cmd("debug.referenceSeed", { slot: true, name: "Blue Monday (master)", monitoring: true, matchGainDb: -6.2 });
await sleep(400);
const shaSeedRow = await capture("C6b-strip-row-present-monitoring");
check("C6 the seeded strip row is present/absent by slot alone", shaSeedRow !== shaSeedNoRow);

// C7 unknown key teaches
r = await cmd("debug.referenceSeed", { bogusKey: 1 });
check("C7 an unknown seed key is refused with a teaching error",
  !r.ok && /unknown key/.test(JSON.stringify(r)), JSON.stringify(r).slice(0, 220));

console.log("=== SECTION D — TEARDOWN BACK TO LIVE ===");
r = await cmd("debug.referenceSeed", { clear: true });
check("D1 clear drops the override and closes the panel",
  r.ok && r.result.cleared === true, JSON.stringify(r));
r = await cmd("debug.referenceSeed");
check("D1b post-clear bare read is unseeded again",
  r.ok && r.result.seeded === false && r.result.panel === false, JSON.stringify(r));

// D2 the LIVE slot survived every seed (the store was never touched)
r = await cmd("reference.status");
check("D2 seeding never mutated the store — the real slot is intact",
  r.ok && r.result.reference?.name === "Orch Reference"
    && Math.abs(r.result.reference.offsetSeconds - 0.3) < 1e-9
    && Math.abs(r.result.reference.trimDb + 2.5) < 1e-9,
  JSON.stringify(r).slice(0, 260));

// D3 remove, then the teaching error on an empty slot
r = await cmd("reference.remove");
check("D3 reference.remove clears the slot", r.ok && r.result.removed === true, JSON.stringify(r));
r = await cmd("reference.setMonitor", { on: true });
check("D3b monitoring an empty slot refuses with the teaching error",
  !r.ok && /reference/i.test(JSON.stringify(r)), JSON.stringify(r).slice(0, 220));
const shaAfterRemove = await capture("D3-strip-row-absent-after-remove");
check("D3c the row is gone from the strip again", shaAfterRemove !== shaRow);

// ── SECTION E — the chip-width regression (found in independent pixel review) ──
// A wide match-gain readout used to squeeze the shared MIX|REF chip down to
// "M… | R…" on the master strip: the row had ~18 pt of slack, but HStack was
// SPLITTING its proposal rather than overflowing. Both the chip and the readout
// now pin their widths. `ReferenceSlot.trimRangeDb` (±24) bounds the readout at
// 8 glyphs, so ±24.0 is the true worst case, not a synthetic one. These legs
// re-stage every width the law can produce; the pixel assertion is that the
// chip is IDENTICAL across all of them while the readout alone changes, so a
// future layout edit that re-breaks the pin shows up as a matching sha.
//
// ⚠️ m23-be REPOINTED these legs. The section promised that assertion and never
// made it: it hashed the whole window, which contained neither the chip nor the
// readout (see the framing note at the top), so its verdict came from live
// chrome elsewhere on screen. E0 measures where the two surfaces are, E2/E2c
// crop to them, and E2b proves in pixels that they are actually drawn. The
// ±24.0 collision the old leg reported was an artefact of hashing a window the
// chip is not in — the chip distinguishes sign perfectly: `matchGainText` is
// `%+.1f` (always signed) and `ceilingLimited` swings the tint from cyan to
// amber, which E2b's diff sees as ~3.8 k pixels of change.
console.log("=== SECTION E — CHIP WIDTH ACROSS THE FULL MATCH-GAIN RANGE ===");
await cmd("debug.referenceSeed", { clear: true });
r = await cmd("debug.referenceSeed", { name: "Orch Ref Alpha", monitoring: true,
                                       matchGainDb: -5.8, ceilingLimited: false, panel: false });
await sleep(400);

// E0 — WHERE the two surfaces are, measured. The row's `.explainable` frame and
// `debug.captureUI`'s `rect`/`scale` (m23-ag) turn points into image rows with
// no hand-derived correction, so the legs below crop the surface they NAME.
//
// ⚠️ A reported frame is a MOUNT, not a rasterization: the strip clips its own
// content, so a row can sit inside the window and still not be drawn. MEASURED,
// not argued — put the framing back the way m23-be found it (inserts expanded)
// and this gate reports E0b PASS while E2's five readout crops come back as one
// repeated sha and E2b reports "(no pixel moved)". E0b is therefore necessary
// and NOT sufficient; E2b is the pixel corroboration.
const geo = await referenceRowFrames();
const rowFrame = geo.frames?.referenceRow?.[0];
const chipFrame = geo.frames?.referenceABToggle?.[0];
check("E0 the REFERENCE row and its A/B chip report measured frames",
      !!rowFrame && !!chipFrame && !!geo.captureOrigin && !!geo.captureSize,
      JSON.stringify(geo).slice(0, 300));
const anchor = await captureFrame("E0-row-framing");
const scale = anchor.height / geo.captureSize.height;
const toPx = (x, y, w, h) => ({
  x: Math.round((x + geo.captureOrigin.x) * scale),
  y: Math.round((y + geo.captureOrigin.y) * scale),
  w: Math.round(w * scale), h: Math.round(h * scale),
});
// Line 2 splits at the chip's trailing edge: chip on the left, the SF Mono
// match-gain readout on the right. Both boxes span the row's FULL height so the
// readout's 3 pt glow cannot bleed out of the box it belongs to.
const chipEndX = chipFrame.x + chipFrame.width;
const chipBox = toPx(rowFrame.x, rowFrame.y, chipEndX - rowFrame.x, rowFrame.height);
const readoutBox = toPx(chipEndX, rowFrame.y,
                        rowFrame.x + rowFrame.width - chipEndX, rowFrame.height);
console.log(`   row ${JSON.stringify(rowFrame)} chip ${JSON.stringify(chipFrame)}`);
console.log(`   scale ${scale} → chip px ${JSON.stringify(chipBox)} readout px ${JSON.stringify(readoutBox)}`);
check("E0b both crop boxes lie inside the rasterized content",
      chipBox.x >= 0 && chipBox.y >= 0 && readoutBox.w > 0 && chipBox.w > 0
        && readoutBox.x + readoutBox.w <= anchor.width
        && readoutBox.y + readoutBox.h <= anchor.height,
      `image ${anchor.width}x${anchor.height}`);

const readoutShas = [], chipShas = [], framePaths = [];
for (const [tag, gain] of [["E-gain-minus5_8", -5.8], ["E-gain-plus11_4", 11.4],
                           ["E-gain-plus19_0", 19.0], ["E-gain-minus24_0", -24.0],
                           ["E-gain-plus24_0", 24.0]]) {
  r = await cmd("debug.referenceSeed", { name: "Orch Ref Alpha", monitoring: true,
                                         matchGainDb: gain, ceilingLimited: gain > 0,
                                         panel: false });
  check(`E1 ${tag} staged`, r.ok && Math.abs(r.result.matchGainDb - gain) < 1e-9,
        JSON.stringify(r.result ?? r.error));
  await sleep(400);
  const shot = await captureFrame(tag);
  framePaths.push(shot.path);
  readoutShas.push(cropSha(shot.path, readoutBox));
  chipShas.push(cropSha(shot.path, chipBox));
  console.log(`      readout ${readoutShas.at(-1)}  chip ${chipShas.at(-1)}`);
}
// E2 — every value must REPAINT THE READOUT. Cropped, not whole-window: an
// echoed `matchGainDb` proves the seam recorded the value, never that the view
// drew it, and a whole-window sha answers with whatever else happened to move.
check("E2 each match-gain value repaints the match-gain readout",
  new Set(readoutShas).size === readoutShas.length, readoutShas.join(" "));
// E2b — the leg that would have caught m23-be on day one: flipping the sign at
// the widest value must move pixels, and ONLY inside the readout. Non-null
// proves the seed reached the VIEW and the row is genuinely rasterized;
// containment proves the crop box is over the readout and that nothing else in
// the window is drifting, which is what makes E2's five shas honest evidence.
const signBox = diffBox(framePaths[3], framePaths[4]);
check("E2b −24.0 → +24.0 moves pixels, and ONLY inside the match-gain readout",
  inside(readoutBox, signBox),
  `${boxStr(signBox)} vs readout box ${JSON.stringify(readoutBox)}`);
// E2c — the pin this section exists for, finally asserted. The m22-g P3
// regression was the readout's width squeezing the shared MIX|REF chip down to
// "M… | R…"; with the widths pinned the chip is byte-identical at every gain
// the law can produce.
//
// MEASURED teeth (m23-be — the mutation that reddens it is NOT the obvious
// one). At today's widths line 2 has real slack (chip 65 + readout 43 inside
// 132), so removing EITHER `.fixedSize` alone changes nothing: the `Spacer`
// absorbs the residual and no child is ever squeezed. The leg bites when the
// readout OUTGROWS the slack — widen the "dB" unit and drop the chip's own pin
// in `ReferenceABToggle` and the five chip shas fan out (75d6f3f5 / d576b9ab ×2
// / 91c6c22b / 1216db16, i.e. the chip resizing per glyph); put the chip's pin
// back with the readout still outgrown and it returns to one sha. So
// `ReferenceABToggle.fixedSize` is the load-bearing one, and this leg is what
// notices if a future edit grows the readout past the row's slack.
check("E2c the A/B chip is pixel-IDENTICAL at every match gain (the width pin)",
  new Set(chipShas).size === 1, chipShas.join(" "));
// E2d — the SIGN, isolated, because E2 alone cannot see it. The five legs above
// seed `ceilingLimited: gain > 0`, so the ±24 pair differs in TINT as well as in
// sign: a readout that had lost its sign entirely would still repaint on the
// colour change and sail through E2 (MEASURED — dropping the sign from
// `ReferencePanelModel.matchGainText` leaves E2/E2b/E2c all green). This leg
// holds the clamp state fixed and moves ONLY the sign, at the widest value
// `ReferenceSlot.trimRangeDb` allows.
//
// It is the m23-be question asked properly: *does the chip still distinguish
// boost from cut at the extreme?* It does — `matchGainText` is `%+.1f`, so the
// glyph is always there — and this is the leg that keeps it true.
const signShas = [];
for (const [tag, gain] of [["E-sign-minus24-unclamped", -24.0],
                           ["E-sign-plus24-unclamped", 24.0]]) {
  r = await cmd("debug.referenceSeed", { name: "Orch Ref Alpha", monitoring: true,
                                         matchGainDb: gain, ceilingLimited: false,
                                         panel: false });
  check(`E2d-stage ${tag}`, r.ok && Math.abs(r.result.matchGainDb - gain) < 1e-9,
        JSON.stringify(r.result ?? r.error));
  await sleep(400);
  const shot = await captureFrame(tag);
  signShas.push(cropSha(shot.path, readoutBox));
  console.log(`      readout ${signShas.at(-1)}`);
}
check("E2d at ONE clamp state, −24.0 and +24.0 still read differently (the sign survives)",
  signShas[0] !== signShas[1], signShas.join(" "));
// Panel non-regression: the 22 pt instance of the SAME component at the widest value.
r = await cmd("debug.referenceSeed", { matchGainDb: 24.0, ceilingLimited: true, panel: true });
check("E3 panel opens at the widest gain", r.ok && r.result.panel === true, JSON.stringify(r));
await sleep(500);
await capture("E3-panel-widest-gain");
await cmd("debug.referenceSeed", { panel: false });
// Explain-card anchoring survives the pin, on BOTH instances of the shared id.
r = await cmd("debug.explainMode", { on: true, focus: "referenceABToggle" });
check("E4 explain focuses the shared A/B id", r.ok && r.result.focus === "referenceABToggle",
      JSON.stringify(r.result ?? r.error));
await sleep(400);
await capture("E4-explain-strip-chip");
await cmd("debug.explainMode", { on: false });

// ── SECTION F — debug.referenceSeed is INCREMENTAL ──
// Staged facts must survive a later call that mentions only view state; a
// rebuild-from-defaults here silently misleads a gate author who stages in two
// steps (the loudness came back as the -9.4/-0.9/5.2 sample, not what was set).
console.log("=== SECTION F — SEED CARRY-FORWARD ACROSS INCREMENTAL CALLS ===");
await cmd("debug.referenceSeed", { clear: true });
r = await cmd("debug.referenceSeed", {
  name: "Carry Ref", integratedLufs: -8.2, truePeakDbtp: -0.4, loudnessRangeLu: 7.1,
  mixLufs: -15.5, mixTruePeakDbtp: -3.3, mixLra: 9.9, monitoring: true });
check("F1 facts staged", r.ok && Math.abs(r.result.mixIntegratedLufs + 15.5) < 1e-9,
      JSON.stringify(r.result ?? r.error));
r = await cmd("debug.referenceSeed", { panel: true, mix: true });
check("F2 a panel-only call carries the mix loudness forward",
      r.ok && Math.abs(r.result.mixIntegratedLufs + 15.5) < 1e-9,
      `mixIntegratedLufs=${r.result?.mixIntegratedLufs} (want -15.5)`);
await sleep(400);
await capture("F2-panel-carried-facts");
r = await cmd("debug.referenceSeed", { trimDb: -2.0 });
check("F3 an unrelated field carries loudness AND applies the trim",
      r.ok && Math.abs(r.result.mixIntegratedLufs + 15.5) < 1e-9
        && Math.abs(r.result.trimDb + 2.0) < 1e-9, JSON.stringify(r.result ?? r.error));
r = await cmd("debug.referenceSeed");
check("F4 a bare read still does not mutate", r.ok && r.result.slot === "Carry Ref"
      && Math.abs(r.result.mixIntegratedLufs + 15.5) < 1e-9, JSON.stringify(r.result ?? r.error));
r = await cmd("debug.referenceSeed", { mix: false });
check("F5 mix:false still DROPS by name", r.ok && r.result.mixIntegratedLufs === null,
      JSON.stringify(r.result ?? r.error));
await cmd("debug.referenceSeed", { clear: true });
// Put the sticky INSERTS disclosure back the way we found it (see the framing
// note at the top): the flag outlives this process, and a gate that silently
// re-frames the next one is the ambient-state defect m23-be diagnosed.
// m23-du(b): via the idempotent helper, which the throw-path handlers share.
await restoreAmbient("normal exit");

console.log(`\n=== ${pass} PASS / ${fail} FAIL ===`);
stopStaging(GATE);   // SIGTERMs by exact pid AND releases our session.lock
ws.close();
process.exit(fail ? 1 : 0);
