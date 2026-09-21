// _m39af-dyneq-card-probe — G8: LOOK AT THE 32-PARAMETER CARD.
//
// WHY THIS EXISTS. `.dynamicEQ` ships 32 params — four bands of eight — which is
// by a wide margin the largest built-in effect card in the app. Every other
// check on this kind was a number: bytes, dB, slot counts. Nobody has LOOKED.
// The standing law is explicit: A UI PHASE ISN'T DONE UNTIL SOMEONE LOOKED AT
// IT. The handoff page now tells the user "four of them at once", so the claim
// is in front of them and the card behind it is unverified.
//
// TWO THINGS ARE BEING MEASURED, AND ONLY ONE OF THEM IS A NUMBER:
//
//  (1) MECHANICAL — does every param `fx.describe` advertises actually REACH the
//      card? The card builds its rows from the effect's own param list, so a
//      name mismatch does not fail to compile, it silently renders a shorter
//      card. Driven from `fx.describe` (schema), never a hardcoded list of 32.
//
//  (2) PIXELS — the capture. The named fallback in the design is THREE bands;
//      4x8 was the thing that might not fit. Captured at a generous window AND
//      at the 672 pt content floor (`WindowFloor.minWindowContentHeight`, the
//      smallest the window can actually be), because "it fits on my screen" is
//      not the claim — "it fits at the floor" is.
//
// AND THE DEBT THIS ALSO CLOSES: `band1Mode`...`band4Mode` are four MODE
// SWITCHES. On this card `detectorMode`, clipper `mode`, ringmod `waveform`,
// phaser `stages` and saturator `oversampling` all render as KNOBS, and nobody
// has looked at that either. This capture shows four more of them at once, so
// one look settles both questions.
//
// NOT A SCORED GATE (leading `_`): its verdict is a PNG a human reads. The
// mechanical legs are scored so a regression is loud, but a green here does NOT
// mean the card is good — only that it is populated.
//
// m23-ge: `debug.effectEditor {open}` writes panelDensity.mixer into the real
// prefs domain as a side effect. `panelDensityDomainGuard` snapshots and
// reconciles on both the normal and throw paths — same shape as m17a.
import {
  buildOrAbort, startStaging, stopStaging, connect, sleep, panelDensityDomainGuard, verdict,
} from "./_staging.mjs";

const GATE = "m39af-dyneq-card";
const SCRATCH = `/tmp/daw-gate-out/${GATE}`;
// The session scratchpad — where I can actually Read the PNG back.
const LOOK = "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/"
  + "cc1b3823-79f0-4b80-950f-ca6f315857d1/scratchpad";

buildOrAbort({ label: "building staging binary (m39af card probe)…" });
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

  // Pin the window and CONFIRM the pin took (m23-bg): a pin's own echo is not
  // proof. Unpinned, this probe inherits whatever size the last gate left in
  // the shared autosave domain, and the whole point here is the size.
  {
    let wf = null;
    for (let i = 0; i < 20 && !(wf && typeof wf.width === "number"); i++) {
      wf = (await cmd("debug.windowFrame", {})).result;
      if (!(wf && typeof wf.width === "number")) await sleep(250);
    }
    ck("window exists pre-pin", wf && typeof wf.width === "number", JSON.stringify(wf));
    await cmd("debug.windowFrame", { width: 1400, height: 1000 });
    await sleep(300);
    wf = (await cmd("debug.windowFrame", {})).result;
    console.log(`  pin: requested 1400x1000, confirmed ${wf?.width}x${wf?.height}`);
    ck("pin took (re-read matches request)", wf?.width === 1400 && wf?.height === 1000, JSON.stringify(wf));
  }

  let r = await cmd("project.new");
  ck("project.new ok", r.ok, r.error);

  // ---- the param list comes from the APP, not from me ----
  r = await cmd("fx.describe", { kind: "dynamicEQ" });
  const dqParams = r.result?.kinds?.[0]?.params ?? [];
  console.log(`  fx.describe dynamicEQ -> ${dqParams.length} params`);
  ck("fx.describe knows dynamicEQ", dqParams.length > 0,
    JSON.stringify(r.result)?.slice(0, 200));
  ck("fx.describe advertises 32 params", dqParams.length === 32, `got ${dqParams.length}`);

  r = await cmd("track.add", { kind: "audio", name: "DynEQ card probe" });
  const tid = (r.result?.track ?? r.result)?.id;
  ck("track add ok", r.ok && !!tid, r.error);

  r = await cmd("fx.add", { trackId: tid, kind: "dynamicEQ" });
  const eid = r.result?.effectId ?? r.result?.effect?.id;
  ck("fx.add dynamicEQ ok", r.ok && !!eid, JSON.stringify(r.result)?.slice(0, 200));

  // ---- (1) MECHANICAL: does every advertised param reach the card? ----
  r = await cmd("debug.effectEditor", { trackId: tid, effectId: eid, open: true });
  ck("dynamicEQ card opens", r.ok && r.result?.visible === true,
    JSON.stringify(r.result)?.slice(0, 200));
  const values = r.result?.values ?? {};
  const cardNames = Object.keys(values);
  console.log(`  card exposes ${cardNames.length} values`);
  const missing = dqParams.map(p => p.name).filter(nm => typeof values[nm] !== "number");
  ck("EVERY describe param reaches the card as a number",
    missing.length === 0, `missing ${missing.length}: ${missing.slice(0, 8).join(",")}`);
  // A card with EXTRA keys is not a failure (result-echo fields exist), but say so.
  const extra = cardNames.filter(nm => !dqParams.some(p => p.name === nm));
  console.log(`  card extras (echo fields, not a defect): ${extra.join(",") || "none"}`);

  // The four mode switches, named explicitly — this is the "switches wearing
  // knobs" debt. Their presence is mechanical; how they LOOK is the capture.
  for (const b of [1, 2, 3, 4]) {
    ck(`band${b}Mode present on the card`, typeof values[`band${b}Mode`] === "number",
      String(values[`band${b}Mode`]));
  }

  // ---- (2) GEOMETRY + PIXELS ----
  r = await cmd("debug.explainMode", { on: true });
  ck("explain mode on", r.result?.on === true, JSON.stringify(r.result));
  await sleep(400);
  r = await cmd("debug.explainFrames", {});
  const frames = r.result?.frames ?? {};
  const ids = Object.keys(frames);
  console.log(`  explainFrames ids (${ids.length}): ${ids.slice(0, 24).join(", ")}`);
  // Do NOT assume an id name — report what is actually there and let the
  // capture carry the verdict. A hardcoded id that does not exist would read as
  // "no frame" and look like a finding.
  const cardish = ids.filter(k => /effect|insert|card|editor/i.test(k));
  console.log(`  candidate card frames: ${cardish.join(", ") || "NONE — capture is the only instrument"}`);
  for (const k of cardish) {
    const f = frames[k]?.[0];
    if (f) console.log(`    ${k}: ${f.width}x${f.height} @ (${f.x},${f.y})`);
  }

  r = await cmd("debug.captureUI", { path: `${LOOK}/dyneq-card-1400x1000.png` });
  ck("captured at 1400x1000", r.ok, r.error);

  // THE REAL TEST: the window content floor. 672 pt is where a 4x8 grid is most
  // likely to overflow or clip, and it is a size the user can actually produce.
  await cmd("debug.windowFrame", { width: 1100, height: 672 });
  await sleep(600);
  const small = (await cmd("debug.windowFrame", {})).result;
  console.log(`  floor window: requested 1100x672, got ${small?.width}x${small?.height}`);
  r = await cmd("debug.explainFrames", {});
  const smallFrames = r.result?.frames ?? {};
  for (const k of cardish) {
    const f = smallFrames[k]?.[0];
    if (f) console.log(`    at floor ${k}: ${f.width}x${f.height} @ (${f.x},${f.y})`);
  }
  r = await cmd("debug.captureUI", { path: `${LOOK}/dyneq-card-1100x672.png` });
  ck("captured at the 672 pt floor", r.ok, r.error);

  await cmd("debug.explainMode", { on: false });
  r = await cmd("debug.effectEditor", { close: true });
  ck("card closes", r.ok && r.result?.visible === false, JSON.stringify(r.result)?.slice(0, 120));

  console.log(`CARD_PROBE pass=${pass} fail=${fail}`);
  console.log("  ⚠️  A GREEN HERE MEANS POPULATED, NOT GOOD. Read the two PNGs.");
} catch (e) {
  fail++; console.log(`FAIL exception :: ${e.stack}`);
} finally {
  await domainGuard?.restore("finally");
  try { ws?.close(); } catch { /* ignore */ }
  stopStaging(GATE);   // SIGTERM by exact pid + release our session.lock
}
verdict({ ran: pass + fail, failed: fail });
