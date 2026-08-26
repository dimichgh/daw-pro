// m28-knob-ui — BREATH PAD HARDWARE SECTION RENDER PROBE (an instrument AND a
// gate for the one hard rule).
//
// WHY THIS EXISTS, in two parts:
//
// 1. **A UI phase is not done until someone has LOOKED at it.** This same card
//    shipped at m28-p7 with WRITE THE SHAPE clipped off the bottom of the window
//    — and every test in that round stayed green, because they all consumed a
//    `fixedChrome` constant that was 53 pt light. This round ADDS a whole
//    section to that card, so the two layout constants it touches are MEASURED
//    here, from the panel's own report, and never summed or estimated.
//
// 2. **Opening the pad must not bring the CoreMIDI client up.** Arming learn
//    creates the client and connects to every online source on the user's desk.
//    A headless suite proves the store is never asked; this proves it on a REAL
//    running app, through the same route a human takes.
//
// Port law: staging 17695 ONLY. 17600 is the user's app and is never a target.
import {
  launchStaging, stopStaging, STAGING_PORT, LIVE_PORT, assertStagingPort,
} from "./_staging.mjs";

const GATE = "m28knobui-hardware";
const SCRATCH = process.env.M28KNOBUI_SCRATCH
  || "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad";

assertStagingPort(STAGING_PORT);
if (STAGING_PORT === LIVE_PORT) { console.log("FAIL port law"); process.exit(1); }

let pass = 0, fail = 0;
const ck = (name, ok, detail = "") => {
  if (ok) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name} :: ${String(detail).slice(0, 400)}`); }
};

let ws, id = 0;
const cmd = (command, params = {}) => new Promise((res, rej) => {
  const i = `m28ku${++id}`;
  const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 25000);
  const h = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id !== i) return;
    clearTimeout(t); ws.removeEventListener("message", h); res(m);
  };
  ws.addEventListener("message", h);
  ws.send(JSON.stringify({ id: i, command, params }));
});

const layout = (l) => `available=${l?.layoutAvailable} drawn=${l?.layoutCardHeight} `
  + `predicted=${l?.layoutPredictedCard} dial=${l?.layoutDialSide} overhang=${l?.layoutOverhang} `
  + `section=${l?.hardwareSectionHeight}`;

// ⚠️ "PREDICTED == DRAWN" IS ONLY MEANINGFUL WHILE THE CARD FITS. Once the
// cascade's third step engages the card is CLAMPED to its room, so `drawn`
// stops being the card's natural height and becomes the window's — and an
// equality check there would be comparing the budget against the clamp. The
// budget's job in that state is the OPPOSITE claim: predict a card too tall to
// fit, which is the signal the view scrolls on. Assert whichever one applies,
// so neither state is silently unchecked.
// ⚠️ THE BRANCH IS PICKED BY `predicted`, NOT BY `drawn`. Picking it by
// `drawn < room` was WRONG at the boundary and the run proved it: at a 1018 pt
// window the budget shrank the dial until the card was EXACTLY its room —
// predicted 970, drawn 970, room 970 — which is a perfect fit and was
// classified as a scroll. The view's own rule is `cardHeight(...) > room`, so
// the budget's claim is the discriminator; `drawn` is the thing being checked
// and cannot also be the thing that chooses the check.
const budgetHonest = (l) => {
  const room = (l?.layoutAvailable ?? 0) - 48; // windowMargin * 2
  const drawn = l?.layoutCardHeight ?? 0;
  const predicted = l?.layoutPredictedCard ?? -999;
  if (predicted <= room) {
    return { ok: Math.abs(drawn - predicted) <= 2, mode: "fits" };
  }
  return { ok: Math.abs(drawn - room) <= 2, mode: "scrolls" };
};

try {
  const s = await launchStaging({ gate: GATE, settleMs: 1500 });
  ws = s.ws;
  console.log(`staging pid=${s.pid} port=${STAGING_PORT}`);

  let r = await cmd("project.new", {});
  ck("project.new", r.ok, r.error);
  r = await cmd("track.add", { name: "Sax", kind: "instrument" });
  const trackId = r.result?.id ?? r.result?.track?.id ?? r.result?.trackId;
  ck("instrument track added", r.ok && !!trackId, r.error);
  const notes = [];
  for (let i = 0; i < 4; i++) notes.push({ pitch: 69, startBeat: i * 4, lengthBeats: 4, velocity: 96 });
  for (let i = 0; i < 4; i++) notes.push({ pitch: 71, startBeat: 18 + i * 4, lengthBeats: 4, velocity: 96 });
  r = await cmd("clip.addMIDI", { trackId, lengthBeats: 35, notes });
  const clipId = r.result?.id ?? r.result?.clip?.id ?? r.result?.clipId;
  ck("MIDI clip added", r.ok && !!clipId, r.error);
  await cmd("track.setInstrument", { trackId, kind: "polySynth" });

  // ================================================================
  // 1. THE HARD RULE: opening the pad leaves the MIDI client alone.
  // ================================================================
  //
  // `midi.getControlMap` reports `subscribed`, which is
  // `MIDIControlController.isSubscribed` — true only when the engine is
  // actually holding our control-change observer, i.e. the CoreMIDI client
  // exists and is connected to every online source. It must be FALSE after the
  // panel has been opened, expanded and photographed.
  let before = await cmd("midi.getControlMap", {});
  ck("baseline: not subscribed before the pad is opened",
    before.result?.subscribed === false, JSON.stringify(before.result)?.slice(0, 300));

  r = await cmd("debug.breathPad", { clipId, open: true });
  ck("pad OPENS", r.ok && r.result?.visible === true, r.error);
  ck("⛔ opening the pad did NOT wake CoreMIDI",
    r.result?.hardwareSubscribed === false,
    `hardwareSubscribed=${r.result?.hardwareSubscribed}`);
  ck("the section starts COLLAPSED", r.result?.hardwareExpanded === false,
    `expanded=${r.result?.hardwareExpanded}`);
  console.log(`  collapsed summary : ${r.result?.hardwareSummary}`);
  console.log(`  feed line         : ${r.result?.hardwareFeedLine}`);
  console.log(`  last heard        : ${r.result?.hardwareLastHeard}`);

  // Park the dot on the LONGEST summary so every height below is the worst
  // case the `summaryReservation` has to cover.
  await cmd("debug.breathPad", { pattern: "subToneEntry", radius: 1 });
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m28ku-collapsed.png` });
  ck("captured: pad open, hardware COLLAPSED", r.ok, r.error);
  const collapsed = (await cmd("debug.breathPad", {})).result;
  console.log(`  layout COLLAPSED  : ${layout(collapsed)}`);

  // ================================================================
  // 2. EXPANDED — the state the height budget has never seen.
  // ================================================================
  r = await cmd("debug.breathPad", { hardwareExpanded: true });
  ck("the section expands", r.result?.hardwareExpanded === true, r.error);
  ck("⛔ expanding did NOT wake CoreMIDI either",
    r.result?.hardwareSubscribed === false,
    `hardwareSubscribed=${r.result?.hardwareSubscribed}`);
  ck("both targets have a row",
    Array.isArray(r.result?.hardwareRows) && r.result.hardwareRows.length === 2,
    JSON.stringify(r.result?.hardwareRows)?.slice(0, 400));
  ck("every row reads NOT MAPPED before any learn",
    (r.result?.hardwareRows ?? []).every((row) => row.bound === false
      && row.learning === false && row.status === "Not mapped"),
    JSON.stringify(r.result?.hardwareRows)?.slice(0, 400));
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m28ku-expanded.png` });
  ck("captured: pad open, hardware EXPANDED", r.ok, r.error);
  const expanded = (await cmd("debug.breathPad", {})).result;
  console.log(`  layout EXPANDED   : ${layout(expanded)}`);

  // ⭐ THE MEASUREMENT. `hardwareExpandedChrome` is the DIFFERENCE between the
  // two drawn cards at the same window, read off the panel's own report — not
  // summed from paddings, which was wrong by 61 pt for `fixedChrome`, and not
  // scanned off a capture, which was wrong by 53.
  // ⛔ MEASURED FROM THE SECTION, NOT FROM THE CARD. The card difference is a
  // TRAP on a short display: the expanded card is clamped by the scroll cascade,
  // so the two drawn cards differ by whatever the clamp left over (21.5 pt in
  // the first run, against a section an order of magnitude taller). The section
  // is never clamped — a ScrollView's content keeps its natural height — so this
  // subtraction is honest at any window size.
  const delta = (expanded?.hardwareSectionHeight ?? 0) - (collapsed?.hardwareSectionHeight ?? 0);
  console.log(`  MEASURED hardwareExpandedChrome = ${delta}   `
    + `(section ${collapsed?.hardwareSectionHeight} -> ${expanded?.hardwareSectionHeight})`);
  console.log(`  (card difference = ${(expanded?.layoutCardHeight ?? 0) - (collapsed?.layoutCardHeight ?? 0)}`
    + ` — CLAMPED, do not use)`);
  console.log(`  MEASURED fixedChrome (collapsed) = `
    + `${(collapsed?.layoutCardHeight ?? 0) - (collapsed?.layoutDialSide ?? 0)}`);

  // ⭐⭐ THE CONSTANT, PINNED AGAINST THE MEASUREMENT — and this is the check
  // that works at EVERY window size. "predicted == drawn" cannot see this
  // number once the card scrolls, because `drawn` is then the clamp; comparing
  // the budget's constant to the section's own reported delta is a direct
  // reading of the thing itself. If someone adds a row to the section and does
  // not re-measure, THIS goes red.
  ck("BreathPadLayout.hardwareExpandedChrome matches what the section drew",
    Math.abs((expanded?.layoutHardwareChrome ?? -999) - delta) <= 2,
    `constant=${expanded?.layoutHardwareChrome} measured=${delta}`);

  const cb = budgetHonest(collapsed), eb = budgetHonest(expanded);
  ck(`the budget is honest about the COLLAPSED card (${cb.mode})`, cb.ok, layout(collapsed));
  ck(`the budget is honest about the EXPANDED card (${eb.mode})`, eb.ok, layout(expanded));

  // ================================================================
  // 2b. THE EXPANDED CARD AT A WINDOW WHERE IT FITS.
  // ================================================================
  //
  // ⭐ THIS IS THE STRONGEST CHECK OF `hardwareExpandedChrome` AVAILABLE, and it
  // has to run BEFORE the apply. Once warnings and the recovery sentence are on
  // the card, the expanded card exceeds even this display's tallest window and
  // every reading is a clamp again — the budget's "fits" arithmetic would go
  // unexercised while every check stayed green. Order is the whole trick.
  const beforeH = await cmd("debug.windowFrame", {});
  const tall = await cmd("debug.windowFrame", { width: 1440, height: 1600 });
  const tallState = (await cmd("debug.breathPad", {})).result;
  const tb = budgetHonest(tallState);
  console.log(`  layout TALL+EXPANDED: ${layout(tallState)} (mode=${tb.mode})`);
  ck(`the budget is honest at the tallest window this display allows (${tb.mode})`,
    tb.ok, layout(tallState));
  // ⚠️ REPORTED, NOT ASSERTED — and the reason is measured. The tallest window
  // this app can attain is not a constant: two consecutive runs on this machine
  // reported `available` 1018 and then 988, because the frame the window
  // manager grants depends on where the window lands. At 1018 the expanded card
  // FITS exactly (predicted 970 = drawn 970 = room 970, dial yielded to 199.5)
  // and the constant is validated straight through the card arithmetic; at 988
  // it misses by 6.5 and scrolls. Asserting it would be a flake with a display
  // dependency, so it SAYS which branch it got. The constant itself is pinned
  // unconditionally above, against the section's own measurement.
  console.log(tb.mode === "fits"
    ? `  ⭐ the expanded card FITS here — hardwareExpandedChrome validated through the card`
    : `  NOTE: this display topped out at available=${tallState?.layoutAvailable}; the expanded `
      + `card needs ${(tallState?.layoutPredictedCard ?? 0) + 48}. The "fits" branch is `
      + `UNEXERCISED in this run (window height=${tall.result?.height}).`);
  // ⛔⛔ AND NOW ACTUALLY LOOK AT THE SECTION.
  //
  // The previous version of this step captured the window here and logged
  // "captured: the WHOLE expanded section, unclipped" — a PASS on a photograph
  // the section is not in. The numbers above say why: with the section open the
  // card wants 971.5 pt against 934 pt of room at this display's tallest window,
  // so it scrolls and the section sits permanently below the fold. There is no
  // window size on this machine at which the naive capture would have been
  // truthful, and nothing about a green check would have said so.
  //
  // ⭐ A capture is only evidence of what is IN it. Scroll first, then shoot.
  //
  // ⚠️⚠️ AND FORCE A WINDOW WHERE THE CARD DEFINITELY SCROLLS FIRST. This step
  // ran at whatever tall frame the window manager granted above, and on a run
  // where that frame was generous (1050 pt, against the 1019.5 the expanded card
  // needs) the card FIT — so there was no `ScrollViewReader` in the hierarchy at
  // all, `scrollTo` had nothing to do, and the step exercised nothing while
  // passing. A plant against the anchor in that state is INERT, which is the
  // subtler sibling of a green check on an absence: not a test that failed to
  // notice, a test that was not present. 800 pt scrolls on any display.
  await cmd("debug.windowFrame", { width: 1440, height: 800 });
  await cmd("debug.breathPad", { scrollTo: "bottom" });
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m28ku-expanded-fits.png` });
  ck("captured: the card scrolled to its bottom, where the section actually is",
    r.ok, r.error);

  // ================================================================
  // 3. THE LOADED, EXPANDED CARD AT THE WINDOW FLOOR — where a centred
  //    card loses its first and last rows if the budget is wrong.
  // ================================================================
  r = await cmd("debug.breathPad", { angleDegrees: 112.5, radius: 0.82,
                                     airEnforced: true, apply: true });
  ck("applied, so warnings and the gauge are live", r.ok && (r.result?.notesTouched ?? 0) === 8,
    JSON.stringify(r.result)?.slice(0, 300));
  const loaded = (await cmd("debug.breathPad", {})).result;
  console.log(`  layout LOADED+EXP : ${layout(loaded)}`);
  const lb = budgetHonest(loaded);
  ck(`the budget is honest about the LOADED EXPANDED card (${lb.mode})`, lb.ok, layout(loaded));

  const floored = await cmd("debug.windowFrame", { width: 1440, height: 400 });
  ck("the window is at its height floor (clamped, as designed)",
    floored.result?.height === floored.result?.minHeight,
    JSON.stringify(floored.result)?.slice(0, 200));
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m28ku-floor-expanded.png` });
  ck("captured: LOADED + EXPANDED at the window floor", r.ok, r.error);
  const atFloor = (await cmd("debug.breathPad", {})).result;
  console.log(`  layout WINDOW FLOOR: ${layout(atFloor)}`);
  // ⛔ THE ROW THAT MUST NEVER BE LOST. Overhang 0 means the card scrolled
  // instead of overhanging, so WRITE THE SHAPE is still on screen.
  ck("nothing overhangs at the window floor (the card scrolled instead)",
    (atFloor?.layoutOverhang ?? -1) === 0,
    `overhang=${atFloor?.layoutOverhang} available=${atFloor?.layoutAvailable} drawn=${atFloor?.layoutCardHeight}`);
  if (typeof beforeH.result?.height === "number") {
    await cmd("debug.windowFrame", { width: beforeH.result.width, height: beforeH.result.height });
  }

  // ================================================================
  // 4. A MAPPING, WRITTEN THROUGH THE WIRE — the panel must show it.
  // ================================================================
  //
  // ⚠️ `midi.setControlMap` with a non-empty table DOES subscribe (an agent
  // asked for a mapping, which is the user's proxy asking). That is the
  // designed behaviour and is asserted here so the "opening is quiet" checks
  // above are not passing for the trivial reason that nothing ever subscribes.
  // It is the POSITIVE CONTROL for those checks.
  r = await cmd("midi.setControlMap", {
    bindings: [{ target: "breathPadAngle", controller: 74, sourceId: 4242 }],
  });
  ck("wire mapping accepted", r.ok, r.error);
  r = await cmd("debug.breathPad", {});
  ck("the panel picked the wire-written mapping up",
    r.result?.hardwareBoundCount === 1, JSON.stringify(r.result?.hardwareRows)?.slice(0, 400));
  // The device is one this session never enumerated, so the row must NAME it as
  // the number it is rather than inventing a name — resolving it would mean
  // waking CoreMIDI, which is the whole thing this design refuses to do.
  const angleRow = (r.result?.hardwareRows ?? []).find((x) => x.target === "breathPadAngle");
  ck("an un-enumerated device is reported as its NUMBER, not a guess",
    angleRow?.status === "CC 74 · device 4242", angleRow?.status);
  console.log(`  row status        : ${angleRow?.status}`);
  console.log(`  collapsed summary : ${r.result?.hardwareSummary}`);
  await cmd("debug.breathPad", { scrollTo: "bottom" });
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m28ku-mapped.png` });
  ck("captured: a bound row (scrolled into frame first)", r.ok, r.error);

  // POSITIVE CONTROL for every "did NOT wake CoreMIDI" check above: the same
  // field CAN read true, so a false is a real observation and not a field that
  // is always false.
  const after = await cmd("midi.getControlMap", {});
  ck("positive control: with a mapping in place the app IS subscribed",
    after.result?.subscribed === true, JSON.stringify(after.result)?.slice(0, 300));

  // ================================================================
  // 5. ⛔⛔ THE SECTION MUST BE THE SAME HEIGHT IN EVERY STATE.
  // ================================================================
  //
  // ⭐⭐ **THIS IS THE CHECK THE FIRST VERSION OF THIS PROBE WAS MISSING, AND
  // THE ONE THAT MATTERS MOST.** `hardwareExpandedChrome` is a SINGLE number,
  // measured in step 2 in a SINGLE state: unbound and unsubscribed. The section
  // as first written was not one height:
  //
  //   - `feedLine` has three variants, and the one shown in the measured state
  //     ("Not listening yet. Nothing is mapped…") is the LONGEST — two lines at
  //     this width, where the other two fit on one;
  //   - FORGET ALL MAPPINGS appeared only once something was bound.
  //
  // So the state that was sampled is the state the panel leaves the instant the
  // feature is used, and the delta was not even reliably one sign. That is the
  // m28-p7 defect arriving by a different road: budget says it fits, card draws
  // taller, overhang lands on WRITE THE SHAPE, every unit test green because
  // they all consume the same constant.
  //
  // ⚠️⚠️ AND THE SCROLL CASCADE HIDES IT. On this 900 pt display the expanded
  // card always exceeds its room, so it is clamped and nothing LOOKS wrong —
  // the error would surface only at a window where the expanded card just fits,
  // i.e. on a display this machine does not have. A capture cannot find this.
  // Only comparing the section's own reported height ACROSS STATES can.
  //
  // The fix under test is the `summaryReservation` idiom: reserve the worst case
  // (`hardwareFeedReservation`) and keep the destructive button present-but-
  // disabled, so the height is a constant rather than a sample. These four
  // readings must all be equal — and note that the FIRST of them is the tall
  // two-line variant, so this is a real comparison and not four copies of one
  // layout.
  const sectionAt = async (label, bindings) => {
    await cmd("midi.setControlMap", { bindings });
    const s = (await cmd("debug.breathPad", {})).result;
    console.log(`  section [${label}] = ${s?.hardwareSectionHeight}`
      + `   feed="${(s?.hardwareFeedLine ?? "").slice(0, 46)}…"`);
    return s?.hardwareSectionHeight ?? -1;
  };
  const hUnbound = await sectionAt("unbound, 2-line feed", []);
  const hBound = await sectionAt("bound + subscribed",
    [{ target: "breathPadAngle", controller: 74, sourceId: 4242 }]);
  const hInverted = await sectionAt("bound + inverted",
    [{ target: "breathPadAngle", controller: 74, sourceId: 4242, inverted: true }]);
  const hTwo = await sectionAt("both targets bound", [
    { target: "breathPadAngle", controller: 74, sourceId: 4242 },
    { target: "breathPadRadius", controller: 75, sourceId: 4242 },
  ]);
  // ⚠️ AND THE OTHER AXIS THAT HAS ONLY EVER BEEN SAMPLED ONCE: **WIDTH**.
  // Every reading above was taken at a 1440 pt window. The defect this whole
  // step exists for was "one number measured in one state"; a constant measured
  // at one width has exactly the same shape. If the card reflows with the
  // window, a narrow one wraps `feedLine` to three lines and the persistence
  // note to three, and 285 is wrong again — in the state nobody measured.
  const wideAgain = await cmd("debug.windowFrame", {});
  await cmd("debug.windowFrame", { width: 900, height: 1014 });
  const narrow = (await cmd("debug.breathPad", {})).result;
  console.log(`  section [narrow window w=900] = ${narrow?.hardwareSectionHeight}`);
  ck("the section is the same height at a NARROW window too",
    Math.abs((narrow?.hardwareSectionHeight ?? -1) - hTwo) <= 1,
    `narrow=${narrow?.hardwareSectionHeight} wide=${hTwo} — the card reflows with `
    + `width, so hardwareExpandedChrome is width-dependent and cannot be one constant`);
  await cmd("debug.windowFrame",
    { width: wideAgain.result?.width ?? 1440, height: wideAgain.result?.height ?? 1014 });

  const heights = [hUnbound, hBound, hInverted, hTwo];
  const spread = Math.max(...heights) - Math.min(...heights);
  ck("the hardware section is the SAME height in every state (spread <= 1pt)",
    spread <= 1,
    `heights=${JSON.stringify(heights)} spread=${spread} — `
    + `hardwareExpandedChrome is one number and the section must be one height`);
  ck("BreathPadLayout.hardwareExpandedChrome still matches in the BOUND state",
    Math.abs((expanded?.layoutHardwareChrome ?? -999)
      - (hBound - (collapsed?.hardwareSectionHeight ?? 0))) <= 2,
    `constant=${expanded?.layoutHardwareChrome} bound-measured=`
    + `${hBound - (collapsed?.hardwareSectionHeight ?? 0)}`);
  // The armed-learn state has no wire verb (and this round deliberately added
  // none), so it is held invariant STRUCTURALLY instead: every branch of the
  // row's status is `lineLimit(1)` and the header summary is `lineLimit(1)`, so
  // arming cannot change a height. `BreathPadHardwareSiteTests` pins that.
  console.log(`  (armed-learn state held invariant by lineLimit(1), pinned in the site test)`);

  // Clean up so the staging app is not left holding a MIDI client.
  await cmd("midi.setControlMap", { bindings: [] });
  r = await cmd("debug.breathPad", { close: true });
  ck("pad closes", r.ok && r.result?.visible === false, r.error);

  console.log(`M28KNOBUI_PROBE pass=${pass} fail=${fail}`);
} catch (e) {
  fail++;
  console.log(`FAIL exception :: ${e.stack}`);
} finally {
  try { ws?.close(); } catch { /* ignore */ }
  stopStaging(GATE);
  console.log("staging stopped (pidfile-exact)");
}
process.exit(fail === 0 ? 0 : 1);
