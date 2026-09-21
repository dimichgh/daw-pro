// _m39ag-choice-chip-probe — LOOK AT THE CHOICE CHIPS, AND POSITIVE-CONTROL THEM.
//
// WHY THIS EXISTS. m39-ag replaced the knob-with-a-meaningless-number rendering
// of every discrete effect param with a chip that NAMES the setting. The capture
// in `_m39af-dyneq-card-probe.mjs` shows the Dynamic EQ card at its DEFAULTS,
// where every mode is 0 — so every chip reads "Off".
//
// ⭐⭐ A CHIP THAT ALWAYS SAID "Off" WOULD PRODUCE THAT EXACT PICTURE. A capture
// at the default is not evidence the control tracks anything; it is evidence
// that one value renders. So this probe DRIVES each chip to a different setting
// and captures again — and it deliberately includes the OFF-GRID values
// (band3Mode = 0.4, stages = 5, oversampling = 3) that `fx.setParam` CLAMPS
// WITHOUT ROUNDING, because naming what is actually in force at those values is
// the entire point of reading the label through the kind's own snap.
//
// Expected, and each is checked against the wire's OWN echo where it has one:
//   band1Mode 1   -> "Above"      (wire band1ModeLabel "above")
//   band2Mode 2   -> "Below"      (wire band2ModeLabel "below")
//   band3Mode 0.4 -> "Off"        (wire band3ModeLabel "off" — stored 0.4)
//   band4Mode 1.6 -> "Below"      (wire band4ModeLabel "below" — stored 1.6)
//   phaser stages 5 -> "6"        (even-only, tie resolves UP)
//   clipper oversampling 3 -> "4×" (3 rounds UP, deliberately)
//   ringMod waveform 2 -> "Square"
//   compressor detectorMode 1 -> "Band-Pass"  (the widest label in the app)
//   hallReverb freeze 1 -> "Hold"
//
// NOT A SCORED GATE (leading `_`): the mechanical legs are scored so a
// regression is loud, but the verdict is a PNG a human reads.
import {
  buildOrAbort, startStaging, stopStaging, connect, sleep, panelDensityDomainGuard, verdict,
} from "./_staging.mjs";

const GATE = "m39ag-choice-chip";
const LOOK = "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/"
  + "cc1b3823-79f0-4b80-950f-ca6f315857d1/scratchpad";

buildOrAbort({ label: "building staging binary (m39ag choice chip probe)…" });
startStaging({ gate: GATE });
const ws = await connect();
let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `o${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 25000);
    const h = ev => {
      const m = JSON.parse(ev.data);
      if (m.id !== i) return;
      clearTimeout(t); ws.removeEventListener("message", h); res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id: i, command, params }));
  });
}
let pass = 0, fail = 0;
const ck = (name, cond, extra) => {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; console.log("FAIL " + name + (extra !== undefined ? " :: " + extra : "")); }
};

let domainGuard;
try {
  domainGuard = panelDensityDomainGuard(cmd);
  await domainGuard.snapshot();

  await cmd("debug.windowFrame", { width: 1400, height: 1000 });
  await sleep(300);
  let r = await cmd("project.new");
  ck("project.new ok", r.ok, r.error);

  r = await cmd("track.add", { kind: "audio", name: "Choice chip probe" });
  const tid = (r.result?.track ?? r.result)?.id;
  ck("track add ok", r.ok && !!tid, r.error);

  // ---- the Dynamic EQ card: four chips, four DIFFERENT settings ----
  r = await cmd("fx.add", { trackId: tid, kind: "dynamicEQ" });
  const dq = r.result?.effectId ?? r.result?.effect?.id;
  ck("fx.add dynamicEQ ok", r.ok && !!dq, JSON.stringify(r.result)?.slice(0, 160));

  const modeWrites = [
    ["band1Mode", 1, "above"],
    ["band2Mode", 2, "below"],
    ["band3Mode", 0.4, "off"],    // off-grid: CLAMPED, not rounded
    ["band4Mode", 1.6, "below"],  // off-grid: snaps to 2 at render
  ];
  // ⚠️ The echo lives at `result.effects[<ours>].params.<name>Label` — NOT at
  // `result.params`, which is where the first draft of this probe looked and got
  // a confident `undefined` that read like a missing feature. One resolver, so
  // every leg below asks the same way.
  const labelFromResult = (res, effectId, name) =>
    (res?.effects ?? []).find(e => e.id === effectId)?.params?.[`${name}Label`];
  for (const [name, value, wantLabel] of modeWrites) {
    r = await cmd("fx.setParam", { trackId: tid, effectId: dq, name, value });
    const echoed = labelFromResult(r.result, dq, name);
    ck(`${name}=${value} wire echoes "${wantLabel}"`, echoed === wantLabel,
      `got ${JSON.stringify(echoed)} :: ${JSON.stringify(r.result)?.slice(0, 220)}`);
  }
  // The stored value is NOT snapped — that is the documented contract, and it is
  // exactly why the card must read through the snap rather than the field.
  r = await cmd("debug.effectEditor", { trackId: tid, effectId: dq, open: true });
  ck("dynamicEQ card opens", r.ok && r.result?.visible === true,
    JSON.stringify(r.result)?.slice(0, 160));
  const dqv = r.result?.values ?? {};
  console.log(`  stored band1..4Mode: ${[1, 2, 3, 4].map(b => dqv[`band${b}Mode`]).join(", ")}`);
  ck("band3Mode really is STORED as 0.4 (clamped, not rounded)", dqv.band3Mode === 0.4,
    String(dqv.band3Mode));
  ck("band4Mode really is STORED as 1.6 (clamped, not rounded)", dqv.band4Mode === 1.6,
    String(dqv.band4Mode));

  await sleep(400);
  r = await cmd("debug.captureUI", { path: `${LOOK}/m39ag-dyneq-chips.png` });
  ck("captured the Dynamic EQ chips", r.ok, r.error);
  await cmd("debug.effectEditor", { close: true });

  // ---- the compressor's de-ess mode: the WIDEST label in the app ----
  r = await cmd("fx.add", { trackId: tid, kind: "compressor" });
  const comp = r.result?.effectId ?? r.result?.effect?.id;
  await cmd("fx.setParam", { trackId: tid, effectId: comp, name: "detectorMode", value: 1 });
  r = await cmd("debug.effectEditor", { trackId: tid, effectId: comp, open: true });
  ck("compressor card opens", r.ok && r.result?.visible === true);
  await sleep(400);
  r = await cmd("debug.captureUI", { path: `${LOOK}/m39ag-compressor-chip.png` });
  ck("captured Band-Pass, the widest chip label", r.ok, r.error);
  await cmd("debug.effectEditor", { close: true });

  // ---- phaser stages 5 -> "6", and the ring mod's waveform ----
  r = await cmd("fx.add", { trackId: tid, kind: "phaser" });
  const ph = r.result?.effectId ?? r.result?.effect?.id;
  await cmd("fx.setParam", { trackId: tid, effectId: ph, name: "stages", value: 5 });
  r = await cmd("debug.effectEditor", { trackId: tid, effectId: ph, open: true });
  ck("phaser card opens", r.ok && r.result?.visible === true);
  const phv = r.result?.values ?? {};
  console.log(`  stored phaser stages after writing 5: ${phv.stages}`);
  await sleep(400);
  r = await cmd("debug.captureUI", { path: `${LOOK}/m39ag-phaser-chip.png` });
  ck("captured the phaser stages chip", r.ok, r.error);
  await cmd("debug.effectEditor", { close: true });

  r = await cmd("fx.add", { trackId: tid, kind: "ringMod" });
  const rm = r.result?.effectId ?? r.result?.effect?.id;
  r = await cmd("fx.setParam", { trackId: tid, effectId: rm, name: "waveform", value: 2 });
  const wl = labelFromResult(r.result, rm, "waveform");
  ck(`ringMod waveform=2 wire echoes "Square"`, wl === "Square", JSON.stringify(wl));
  r = await cmd("debug.effectEditor", { trackId: tid, effectId: rm, open: true });
  ck("ringMod card opens", r.ok && r.result?.visible === true);
  await sleep(400);
  r = await cmd("debug.captureUI", { path: `${LOOK}/m39ag-ringmod-chip.png` });
  ck("captured the ring mod waveform chip", r.ok, r.error);
  await cmd("debug.effectEditor", { close: true });

  // ---- hallReverb freeze: the one that used to read "0 %" ----
  // ---- hallReverb freeze: the one that used to read "0 %" ----
  // ⚠️ THE CAPTURE DOES NOT SHOW IT, AND THE PRECISE REASON MATTERS. `freeze`
  // lives in this kind's OUTPUT group, the LAST of five on a 14-param card, and
  // `EffectEditorOverlay.sectionsHeight` caps the sections at a hard-coded
  // `min(…, 460)` (~line 188) regardless of window size, so the card measures
  // 340x571 always and MODULATION is cut through the middle of its knobs.
  //
  // ⛔ BUT IT IS **BELOW THE FOLD, NOT UNREACHABLE** — and the difference is a
  // word I nearly got wrong. The sections ARE wrapped in a `ScrollView`
  // (EffectEditorOverlay.swift:302, `.frame(height: sectionsHeight)`), and macOS
  // hides a scroller until you scroll, so a STATIC capture cannot distinguish
  // "clipped away forever" from "you have to scroll". A user can reach freeze.
  // What this leg therefore proves is that the chip is DRIVEN, not that it was
  // SEEN; the unit tests carry the rendering claim for this one kind. The 460 pt
  // cap is a known, separately-tracked defect and is deliberately not fixed here.
  r = await cmd("fx.add", { trackId: tid, kind: "hallReverb" });
  const hr = r.result?.effectId ?? r.result?.effect?.id;
  await cmd("fx.setParam", { trackId: tid, effectId: hr, name: "freeze", value: 1 });
  r = await cmd("debug.effectEditor", { trackId: tid, effectId: hr, open: true });
  ck("hallReverb card opens", r.ok && r.result?.visible === true);
  const hrv = r.result?.values ?? {};
  ck("freeze is driven to 1 on the card's own value surface", hrv.freeze === 1,
    String(hrv.freeze));
  await sleep(400);
  r = await cmd("debug.captureUI", { path: `${LOOK}/m39ag-hallreverb-chip.png` });
  ck("captured the hall reverb card (freeze is BELOW the 460 pt clip)", r.ok, r.error);
  await cmd("debug.effectEditor", { close: true });

  // ---- djFilter slope: the lowercase-s bug the census caught ----
  r = await cmd("fx.add", { trackId: tid, kind: "djFilter" });
  const dj = r.result?.effectId ?? r.result?.effect?.id;
  await cmd("fx.setParam", { trackId: tid, effectId: dj, name: "slopeDbPerOct", value: 24 });
  r = await cmd("debug.effectEditor", { trackId: tid, effectId: dj, open: true });
  ck("djFilter card opens", r.ok && r.result?.visible === true);
  await sleep(400);
  r = await cmd("debug.captureUI", { path: `${LOOK}/m39ag-djfilter-slope.png` });
  ck("captured the DJ filter slope chip (was a knob)", r.ok, r.error);
  await cmd("debug.effectEditor", { close: true });

  console.log(`CHOICE_CHIP_PROBE pass=${pass} fail=${fail}`);
  console.log("  ⚠️  A GREEN HERE MEANS DRIVEN, NOT GOOD. Read the PNGs.");
} catch (e) {
  fail++; console.log(`FAIL exception :: ${e.stack}`);
} finally {
  try { await domainGuard?.restore(); } catch {}
  try { ws.close(); } catch {}
  stopStaging(GATE);
}
verdict({ ran: pass + fail, failed: fail }, { subject: GATE });
