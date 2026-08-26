// m28-p7 — BREATH PAD RENDER PROBE (an instrument, not a gate).
//
// WHY THIS EXISTS: the m26-i sampler card shipped with passing tests, correct
// greps and a clean review, and NOBODY HAD RENDERED IT. A probe later showed
// the zone list collapsed to ~1.7 rows with the inspector open — identical at 3
// zones and at 46. Every headless check in that round would have looked the
// same had the card drawn nothing at all. No gate in this tree can see a pixel.
//
// So this drives a REAL app on staging 17695, opens the pad, PLACES THE DOT
// (a capture at the default position frames the one state that proves nothing
// about the geometry), applies once with air OFF and once with it ON, and
// writes a PNG at each step for a human to look at.
//
// Port law: staging 17695 ONLY. 17600 is the user's app and is never a target.
import {
  launchStaging, stopStaging, STAGING_PORT, LIVE_PORT, assertStagingPort,
} from "./_staging.mjs";

const GATE = "m28p7-breath-pad";
const SCRATCH = process.env.M28P7_SCRATCH
  || "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad";

assertStagingPort(STAGING_PORT);
if (STAGING_PORT === LIVE_PORT) { console.log("FAIL port law"); process.exit(1); }

let pass = 0, fail = 0;
const ck = (name, ok, detail = "") => {
  if (ok) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name} :: ${String(detail).slice(0, 400)}`); }
};

// Browser-style WebSocket (addEventListener / ev.data) — Node's `.on` does not
// exist on it. Copied from _m26i-sampler-card-probe.mjs.
let ws, id = 0;
const cmd = (command, params = {}) => new Promise((res, rej) => {
  const i = `m28p7${++id}`;
  const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 25000);
  const h = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id !== i) return;
    clearTimeout(t); ws.removeEventListener("message", h); res(m);
  };
  ws.addEventListener("message", h);
  ws.send(JSON.stringify({ id: i, command, params }));
});

try {
  const s = await launchStaging({ gate: GATE, settleMs: 1500 });
  ws = s.ws;
  console.log(`staging pid=${s.pid} port=${STAGING_PORT}`);

  let r = await cmd("project.new", {});
  ck("project.new", r.ok, r.error);

  r = await cmd("track.add", { name: "Sax", kind: "instrument" });
  const trackId = r.result?.id ?? r.result?.track?.id ?? r.result?.trackId;
  ck("instrument track added", r.ok && !!trackId, r.error ?? JSON.stringify(r.result));

  // Eight 4-beat notes back to back: 32 beats ≈ 16 s of continuous blowing
  // against the 6 s default capacity, so the air budget CERTAINLY constrains
  // notes and the gauge has something real to draw. A fixture that never runs
  // out would let an empty strip pass for a working one.
  // TWO phrases with a real 2-beat rest between them (1 s at 120 bpm, well over
  // `minBreathSeconds`), so the strip has a BREATH MARK to draw. A one-phrase
  // fixture would leave that half of the gauge unrendered — which is the m26-i
  // failure exactly: verified by tests, never seen.
  const notes = [];
  for (let i = 0; i < 4; i++) {
    notes.push({ pitch: 69, startBeat: i * 4, lengthBeats: 4, velocity: 96 });
  }
  for (let i = 0; i < 4; i++) {
    notes.push({ pitch: 71, startBeat: 18 + i * 4, lengthBeats: 4, velocity: 96 });
  }
  r = await cmd("clip.addMIDI", { trackId, lengthBeats: 35, notes });
  const clipId = r.result?.id ?? r.result?.clip?.id ?? r.result?.clipId;
  ck("MIDI clip with 8 long notes", r.ok && !!clipId, r.error ?? JSON.stringify(r.result));

  // A real instrument, so the drag preview has somewhere to go and the
  // "no instrument yet" warnings do not crowd out the ones about the shape.
  r = await cmd("track.setInstrument", { trackId, kind: "polySynth" });
  ck("instrument set", r.ok, r.error);

  // --- 1. Does the panel OPEN and draw? ---
  r = await cmd("debug.breathPad", { clipId, open: true });
  ck("pad OPENS without throwing", r.ok, r.error);
  ck("pad reports visible", r.result?.visible === true, JSON.stringify(r.result)?.slice(0, 500));
  console.log(`  state: ${JSON.stringify(r.result)?.slice(0, 700)}`);

  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m28p7-pad-open.png` });
  ck("captured: pad open, dot at default", r.ok, r.error);

  // --- 1b. THE SAME CARD, LONGEST SENTENCE. `blendSummary` is DAWCore's prose
  // about the dominant gesture and the eight run 135–255 characters — two
  // rendered lines to four. A block whose height depends on the dot's ANGLE is
  // a height `BreathPadLayout.fixedChrome` cannot see, so the view reserves the
  // worst case. These two captures are the instrument that says the reservation
  // is big enough: NO apply yet, so neither carries warnings, and the card must
  // therefore be EXACTLY as tall with the 255-character summary as with the
  // shortest. A taller card here means the reservation is too small and every
  // layout pin is green anyway (they all consume fixedChrome).
  r = await cmd("debug.breathPad", { pattern: "subToneEntry", radius: 1 });
  ck("parked on the longest summary, nothing applied",
    r.result?.nearestPattern === "subToneEntry" && r.result?.airHasReport !== true,
    JSON.stringify(r.result)?.slice(0, 300));
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m28p7-pad-open-longsummary.png` });
  ck("captured: pad open, LONGEST summary", r.ok, r.error);
  // ⚠️ READ THE STATE **AFTER** THE CAPTURE, NOT FROM IT. The layout report
  // arrives through a SwiftUI preference, so it is one layout pass behind the
  // command that changed the card — and `captureUI`'s response carries no pad
  // state at all. Reading it from the wrong response reports `undefined`, which
  // an `===` comparison would have quietly called a mismatch.
  const longLayout = (await cmd("debug.breathPad", {})).result;
  await cmd("debug.breathPad", { pattern: "flat", radius: 1 });
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m28p7-pad-open-shortsummary.png` });
  ck("captured: pad open, SHORTEST summary", r.ok, r.error);
  r = await cmd("debug.breathPad", {});
  const shortLayout = r.result;
  const layout = (l) => `available=${l?.layoutAvailable} drawn=${l?.layoutCardHeight} `
    + `predicted=${l?.layoutPredictedCard} dial=${l?.layoutDialSide} overhang=${l?.layoutOverhang}`;
  console.log(`  layout, longest summary : ${layout(longLayout)}`);
  console.log(`  layout, shortest summary: ${layout(shortLayout)}`);
  // THE RESERVATION, ASSERTED RATHER THAN EYEBALLED. Same card, same state, two
  // summaries 120 characters apart: if the reservation covers the long one the
  // card is the SAME HEIGHT, and `fixedChrome` is true for all eight gestures.
  ck("the summary's length no longer moves the card",
    longLayout?.layoutCardHeight === shortLayout?.layoutCardHeight
      && (shortLayout?.layoutCardHeight ?? 0) > 0,
    `${longLayout?.layoutCardHeight} vs ${shortLayout?.layoutCardHeight}`);
  // The budget must PREDICT what the card actually draws. This is the number
  // three rounds of pixel archaeology could not pin down.
  ck("the budget predicts the drawn card within 2 pt",
    Math.abs((shortLayout?.layoutCardHeight ?? 0) - (shortLayout?.layoutPredictedCard ?? -999)) <= 2,
    `drawn=${shortLayout?.layoutCardHeight} predicted=${shortLayout?.layoutPredictedCard}`);

  // --- 2. Place the dot OFF-AXIS: 157.5° is exactly between two gestures, so
  // the blend readout must name BOTH. A dot parked on a pattern could not tell
  // a working blend from a hardcoded one.
  // 112.5° is exactly between LATE BLOOM and HAIRPIN CRESCENDO. (157.5° — the
  // midpoint of the two hairpins — is a DEGENERATE blend: a crescendo plus its
  // own mirror is nearly flat, which is mathematically right and makes a poor
  // picture, so it is asserted below rather than captured.)
  r = await cmd("debug.breathPad", { angleDegrees: 112.5, radius: 0.82 });
  ck("dot placed at 112.5° / 0.82",
    Math.abs((r.result?.angleDegrees ?? 0) - 112.5) < 0.001
      && Math.abs((r.result?.radius ?? 0) - 0.82) < 0.001,
    JSON.stringify(r.result)?.slice(0, 300));
  ck("the blend names TWO gestures at a midpoint",
    (r.result?.blend ?? "").split("·").length === 2, r.result?.blend);
  console.log(`  blend: ${r.result?.blend}  effort=${r.result?.effort}`);
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m28p7-pad-dot.png` });
  ck("captured: dot off-axis", r.ok, r.error);

  // --- 2b. A LIVE GESTURE: the dot's glow and its trail exist only while the
  // pointer is down, so they are invisible to every capture that does not stage
  // one. This is the whole reason the debug seam can hold a gesture open.
  await cmd("debug.breathPad", { gesture: "begin" });
  for (const a of [120, 135, 150, 165, 180, 195, 205]) {
    await cmd("debug.breathPad", { angleDegrees: a, radius: 0.9 });
  }
  r = await cmd("debug.breathPad", {});
  ck("a gesture is streaming", r.result?.streaming === true, JSON.stringify(r.result)?.slice(0, 300));
  ck("the trail has crumbs", (r.result?.trailPoints ?? 0) >= 8, `trail=${r.result?.trailPoints}`);
  console.log(`  preview refusal: ${r.result?.previewRefusal}`);
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m28p7-pad-dragging.png` });
  ck("captured: MID-DRAG (glow + trail)", r.ok, r.error);
  // Cancel, not end: a staged gesture must not spend an undo step here.
  r = await cmd("debug.breathPad", { gesture: "cancel" });
  ck("gesture cancelled without committing",
    r.result?.streaming === false && (r.result?.notesTouched ?? 0) === 0,
    JSON.stringify(r.result)?.slice(0, 200));
  await cmd("debug.breathPad", { angleDegrees: 112.5, radius: 0.82 });

  // --- 3. Apply with air OFF: the gauge must show the COUNTERFACTUAL and say
  // WOULD, never DID. This is the legibility contract in the one place a human
  // sees it.
  r = await cmd("debug.breathPad", { airEnforced: false, apply: true });
  ck("apply (air off) succeeded", r.ok && (r.result?.notesTouched ?? 0) === 8,
    JSON.stringify(r.result)?.slice(0, 400));
  ck("air report exists", r.result?.airHasReport === true, JSON.stringify(r.result)?.slice(0, 300));
  ck("air NOT applied", r.result?.airApplied === false, `airApplied=${r.result?.airApplied}`);
  ck("the fixture really runs out of air", (r.result?.airConstrainedNotes ?? 0) > 0,
    `constrained=${r.result?.airConstrainedNotes}`);
  ck("headline says WOULD, not DID", /WOULD/.test(r.result?.airHeadline ?? ""),
    r.result?.airHeadline);
  ck("TWO phrases and a BREATH MARK between them",
    (r.result?.airPhrases ?? 0) === 2 && (r.result?.airBreathMarks ?? 0) === 1,
    `marks=${r.result?.airBreathMarks} phrases=${r.result?.airPhrases}`);
  console.log(`  headline: ${r.result?.airHeadline}`);
  console.log(`  warnings: ${JSON.stringify(r.result?.warnings)?.slice(0, 400)}`);
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m28p7-pad-air-off.png` });
  ck("captured: applied, air OFF (counterfactual gauge)", r.ok, r.error);

  // --- 4. Flip the switch and apply again: same report shape, opposite tense.
  r = await cmd("debug.breathPad", { airEnforced: true, apply: true });
  ck("apply (air on) succeeded", r.ok, r.error);
  ck("air APPLIED", r.result?.airApplied === true, `airApplied=${r.result?.airApplied}`);
  ck("headline no longer says WOULD", !/WOULD/.test(r.result?.airHeadline ?? "WOULD"),
    r.result?.airHeadline);
  console.log(`  headline: ${r.result?.airHeadline}`);
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m28p7-pad-air-on.png` });
  ck("captured: applied, air ON (enforced gauge)", r.ok, r.error);

  // --- 5. Park the dot on ONE gesture and capture: the label highlight and the
  // single-member blend readout.
  r = await cmd("debug.breathPad", { pattern: "subToneEntry", radius: 1 });
  ck("parked on subToneEntry", r.result?.nearestPattern === "subToneEntry",
    JSON.stringify(r.result)?.slice(0, 300));
  ck("a parked dot names ONE gesture",
    (r.result?.blend ?? "").split("·").length === 1, r.result?.blend);
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m28p7-pad-parked.png` });
  ck("captured: dot parked on one gesture", r.ok, r.error);

  // The LOADED card — warnings AND the recovery sentence — which is where the
  // budget is under real pressure and where the dial is supposed to yield.
  r = await cmd("debug.breathPad", {});
  console.log(`  layout, loaded card     : ${layout(r.result)}`);
  ck("the budget predicts the LOADED card within 2 pt",
    Math.abs((r.result?.layoutCardHeight ?? 0) - (r.result?.layoutPredictedCard ?? -999)) <= 2,
    `drawn=${r.result?.layoutCardHeight} predicted=${r.result?.layoutPredictedCard} dial=${r.result?.layoutDialSide}`);
  ck("the loaded card fits the window with its margin intact",
    (r.result?.layoutOverhang ?? -1) === 0,
    `overhang=${r.result?.layoutOverhang} available=${r.result?.layoutAvailable} drawn=${r.result?.layoutCardHeight}`);

  // --- 5b. THE WINDOW FLOOR, WHICH IS WHERE A CENTRED CARD GOES WRONG.
  // `WindowFloor.minHeight` is 640 and the arithmetic says the loaded card
  // cannot fit there even with both regions at their floors. A centred card
  // that overhangs loses its FIRST and LAST rows — the close button and the
  // apply button — so this is not a cosmetic margin question.
  const beforeH = await cmd("debug.windowFrame", {});
  const floored = await cmd("debug.windowFrame", { width: 1440, height: 400 });
  ck("the window is at its height floor (clamped, as designed)",
    floored.result?.height === floored.result?.minHeight,
    JSON.stringify(floored.result)?.slice(0, 200));
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m28p7-pad-window-floor.png` });
  ck("captured: the loaded card at the window floor", r.ok, r.error);
  r = await cmd("debug.breathPad", {});
  console.log(`  layout, WINDOW FLOOR    : ${layout(r.result)}`);
  ck("the card is reachable at the window floor (nothing off-screen)",
    (r.result?.layoutOverhang ?? -1) === 0,
    `overhang=${r.result?.layoutOverhang} available=${r.result?.layoutAvailable} drawn=${r.result?.layoutCardHeight}`);
  if (typeof beforeH.result?.height === "number") {
    await cmd("debug.windowFrame", { width: beforeH.result.width, height: beforeH.result.height });
  }

  // --- 6. The card must FIT. `debug.explainFrames` reports the drawn box; the
  // dial side is the only unknown in `BreathPadLayout.fixedChrome`, so one
  // measurement isolates it. (m25-j FIXED 2026-08-23: explainFrames now reports
  // where a control is DRAWN, offsets included; this probe only ever used w/h,
  // which were correct throughout, so nothing here changes.)
  const frames = await cmd("debug.explainFrames", {});
  const list = frames.result?.frames ?? frames.result?.anchors ?? [];
  console.log(`  explainFrames returned ${Array.isArray(list) ? list.length : "?"} entries`);

  r = await cmd("debug.breathPad", { close: true });
  ck("pad closes", r.ok && r.result?.visible === false, JSON.stringify(r.result)?.slice(0, 200));

  // --- 7. THE ROUTE, NOT JUST THE DESTINATION.
  //
  // Everything above opens the pad through `debug.breathPad`, which calls
  // `openBreathPad(clipID:)` DIRECTLY. So every capture so far proves the panel
  // and proves NOTHING about how a human reaches it. The human route is a third
  // chip in the piano-roll header — a header that already carries a zoom
  // cluster, a snap picker, QUANTIZE, HUMANIZE, a bar-ops cluster, a controller
  // summary, a maximize toggle and a close button. A horizontal stack that has
  // run out of width truncates in silence and looks correct to every headless
  // check in this file.
  //
  // Selecting a MIDI clip IS the rule for "the roll is on screen"
  // (`openEditorClip`), so this needs no new seam.
  r = await cmd("debug.arrangeSelection", { act: "click", clipId });
  ck("clip selected from the arrange", r.ok, r.error);
  r = await cmd("debug.viewZoom", {});
  ck("the piano roll is OPEN (nothing below means anything otherwise)",
    r.result?.rollOpen === true, JSON.stringify(r.result)?.slice(0, 300));
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m28p7-roll-header.png` });
  ck("captured: piano-roll header at the default width", r.ok, r.error);

  // Squeezed. The default window has slack; the question is what the header
  // does when it does not. `WindowFloor.minWidth` is 1208 and `setWindowFrame`
  // CLAMPS to it, so asking for 1040 measures the app's narrowest ATTAINABLE
  // window — the true worst case — and not the number requested. The echo is
  // asserted rather than assumed, because "the request was clamped" and "the
  // request was honoured" produce the same capture path and only one of them is
  // the worst case.
  const before = await cmd("debug.windowFrame", {});
  const squeezed = await cmd("debug.windowFrame", { width: 1040, height: 760 });
  ck("the window is at its floor, 1208 pt (the request was clamped, as designed)",
    squeezed.result?.width === 1208 && squeezed.result?.width === squeezed.result?.minWidth,
    JSON.stringify(squeezed.result)?.slice(0, 200));
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m28p7-roll-header-narrow.png` });
  ck("captured: piano-roll header at the NARROWEST window the app allows", r.ok, r.error);
  const w = before.result?.width, h = before.result?.height;
  if (typeof w === "number" && typeof h === "number") {
    await cmd("debug.windowFrame", { width: w, height: h });
  }

  console.log(`M28P7_PROBE pass=${pass} fail=${fail}`);
} catch (e) {
  fail++;
  console.log(`FAIL exception :: ${e.stack}`);
} finally {
  try { ws?.close(); } catch { /* ignore */ }
  stopStaging(GATE); // SIGTERM by EXACT pid from the pidfile; never pkill
  console.log("staging stopped (pidfile-exact)");
}
process.exit(fail === 0 ? 0 : 1);
