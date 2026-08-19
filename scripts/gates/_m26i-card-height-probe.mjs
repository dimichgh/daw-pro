// m26-i UI half — CARD HEIGHT PROBE: does the DRAWN card agree with the
// arithmetic in `SamplerCardLayout`?
//
// WHY THIS EXISTS, AND WHY IT IS SEPARATE FROM `_m26i-sampler-card-probe.mjs`.
// That probe proves the card OPENS and that the coverage headline tells the
// truth. This one asks the question that outlives it: the card's whole vertical
// budget rests on two HAND-SUMMED constants — `chromeHeight` (266) and
// `inspectorOpenHeight` (308) — that were read off the view by a human adding
// up paddings. Every unit test in the round CONSUMES those constants rather
// than measuring them, so all of them stay green if the numbers are wrong. If
// `chromeHeight` under-states the real chrome, the card overflows its ceiling
// in exactly the state that already failed once (inspector open) and nothing
// in the suite notices.
//
// The instrument is `debug.explainFrames`, which reports the MEASURED frame of
// every `.explainable` control in the live tree. `.explainable(.samplerEditor)`
// sits OUTSIDE the card's padding and background, so the reported height IS the
// card's drawn box.
//
// ⭐ THE TRICK THAT MAKES TWO UNKNOWNS SOLVABLE: measure the same card at two
// zone counts. The zone list's height is known exactly (`height(rows:)`), so
// subtracting it leaves the chrome+inspector LUMP — and the lump is precisely
// what the budget spends. Differencing two zone counts also verifies the ROW
// PITCH in pixels, independently of every other constant.
//
// Port law: staging 17695 ONLY. 17600 is the user's app and is never a target.
import { readFileSync } from "node:fs";
import {
  launchStaging, stopStaging, STAGING_PORT, LIVE_PORT, assertStagingPort, ROOT,
} from "./_staging.mjs";

const GATE = "m26i-card-height";
const SCRATCH = process.env.M26I_SCRATCH
  || "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad";

assertStagingPort(STAGING_PORT);
if (STAGING_PORT === LIVE_PORT) { console.log("FAIL port law"); process.exit(1); }

// ── ONE HOME for the constants: parsed out of the Swift source, never retyped.
// A probe that hardcodes the numbers it is checking checks nothing.
const swift = readFileSync(`${ROOT}/Sources/DAWAppKit/SamplerCardLayout.swift`, "utf8");
const constant = (name) => {
  const m = swift.match(new RegExp(`static let ${name}(?::\\s*CGFloat)?\\s*=\\s*(-?[0-9.]+)`));
  if (!m) throw new Error(`could not parse ${name} out of SamplerCardLayout.swift`);
  return Number(m[1]);
};
const L = {
  rowHeight: constant("rowHeight"),
  rowGap: constant("rowGap"),
  chromeHeight: constant("chromeHeight"),
  inspectorOpenHeight: constant("inspectorOpenHeight"),
  inspectorClosedHeight: constant("inspectorClosedHeight"),
  windowMargin: constant("windowMargin"),
  maxCardHeight: constant("maxCardHeight"),
  minVisibleRows: constant("minVisibleRows"),
  maxRowsWithInspector: constant("maxRowsWithInspector"),
  maxRowsWithoutInspector: constant("maxRowsWithoutInspector"),
};
const rowsHeight = (n) => (n <= 0 ? 0 : n * (L.rowHeight + L.rowGap) - L.rowGap);
const minCardHeight = L.chromeHeight + rowsHeight(L.minVisibleRows); // derived, as in Swift
const cardCeiling = (avail) => Math.min(L.maxCardHeight, Math.max(minCardHeight, avail - L.windowMargin));
const zoneListHeight = (rowCount, open, avail) => Math.min(
  rowsHeight(rowCount),
  rowsHeight(open ? L.maxRowsWithInspector : L.maxRowsWithoutInspector),
  Math.max(cardCeiling(avail) - L.chromeHeight - (open ? L.inspectorOpenHeight : L.inspectorClosedHeight),
    rowsHeight(L.minVisibleRows)),
);
console.log(`constants (parsed): ${JSON.stringify(L)} minCardHeight=${minCardHeight}`);

let pass = 0, fail = 0;
const ck = (name, ok, detail = "") => {
  if (ok) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name} :: ${String(detail).slice(0, 300)}`); }
};

let ws, id = 0;
const cmd = (command, params = {}) => new Promise((res, rej) => {
  const i = `m26ih${++id}`;
  const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 25000);
  const h = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id !== i) return;
    clearTimeout(t); ws.removeEventListener("message", h); res(m);
  };
  ws.addEventListener("message", h);
  ws.send(JSON.stringify({ id: i, command, params }));
});

// A library of `n` zones over existing fixture wavs; contiguous, so the
// coverage line stays quiet and only the ROW COUNT varies.
const library = (n) => Array.from({ length: n }, (_, i) => ({
  path: `${SCRATCH}/zone${(i % 3) + 1}.wav`,
  rootPitch: 36 + i,
  minPitch: i,
  maxPitch: i,
}));

let trackId;
// Measures the card: sets `n` zones, optionally selects the first, and returns
// {height, y, avail}. Selection state is reached by REOPENING (there is no
// deselect param), and the state response is asserted rather than assumed.
const measure = async (n, select) => {
  await cmd("track.setInstrument", { trackId, kind: "sampler", sampler: { zones: library(n) } });
  await cmd("debug.samplerEditor", { close: true });
  let st = await cmd("debug.samplerEditor", { open: true, trackId });
  if (select) {
    const desc = await cmd("instrument.describeSampler", { trackId, offset: 0, limit: 1 });
    st = await cmd("debug.samplerEditor", { zoneId: desc.result?.zones?.[0]?.id });
  }
  const selected = st.result?.selectedZoneId ?? null;
  if (select ? !selected : !!selected) throw new Error(`selection state wrong at n=${n}: ${selected}`);
  const fr = await cmd("debug.explainFrames", { ids: ["samplerEditor"] });
  const rect = fr.result?.frames?.samplerEditor?.[0];
  if (!rect) throw new Error(`no samplerEditor frame at n=${n} (explain mode off? id not in tree?)`);
  const size = fr.result?.captureSize, origin = fr.result?.captureOrigin;
  return {
    height: rect.height, width: rect.width, y: rect.y, zones: n, selected: !!selected,
    // The explain space sits `origin.y` below the content view's top; the
    // overlay's GeometryReader spans that space, so this is the height the
    // card's own budget saw. MEASURED, not a constant.
    avail: (size?.height ?? 0) - (origin?.y ?? 0),
  };
};

try {
  const s = await launchStaging({ gate: GATE, settleMs: 1200 });
  ws = s.ws;
  console.log(`staging pid=${s.pid} port=${STAGING_PORT}`);

  let r = await cmd("project.new", {});
  ck("project.new", r.ok, r.error);
  r = await cmd("track.add", { name: "Height Probe", kind: "instrument" });
  ck("track.add", r.ok, r.error);
  trackId = r.result?.id ?? r.result?.track?.id ?? r.result?.trackId;
  ck("track id returned", !!trackId, JSON.stringify(r.result)?.slice(0, 200));

  // Frames flow ONLY while explain mode is on — without this every rect below
  // is missing and the probe would "find no defect" by finding nothing.
  r = await cmd("debug.explainMode", { on: true });
  ck("explain mode on (frames flow)", r.result?.on === true, JSON.stringify(r.result));

  const closed3 = await measure(3, false);
  const closed6 = await measure(6, false);
  const open3 = await measure(3, true);
  const open20 = await measure(20, true);
  const closed20 = await measure(20, false);
  for (const m of [closed3, closed6, open3, open20, closed20]) {
    console.log(`  measured zones=${m.zones} selected=${m.selected} -> h=${m.height} w=${m.width} y=${m.y} avail=${m.avail}`);
  }

  const avail = closed3.avail;
  const ceiling = cardCeiling(avail);
  console.log(`  available=${avail} ceiling=${ceiling}`);
  ck("explain space has a real height", avail > 200, `avail=${avail}`);

  // POSITIVE CONTROL for the measurement itself: the card is 340 pt wide by
  // construction. If the rect were garbage (wrong space, stale frame) this
  // would not land on the nose.
  ck("measured width is the design's 340", Math.abs(closed3.width - 340) <= 0.5, `w=${closed3.width}`);

  // (1) ROW PITCH, in pixels. 3 more rows must add exactly 3*(26+2) points.
  const rowDelta = closed6.height - closed3.height;
  ck(`3 extra rows add exactly ${rowsHeight(6) - rowsHeight(3)} pt`,
    Math.abs(rowDelta - (rowsHeight(6) - rowsHeight(3))) <= 1,
    `measured delta=${rowDelta}`);

  // (2) THE TWO HAND-SUMMED CONSTANTS. Subtracting the known list height
  // leaves the chrome+inspector lump the budget actually spends.
  const lumpClosed = closed3.height - rowsHeight(3);
  const lumpOpen = open3.height - rowsHeight(3);
  const budgetClosed = L.chromeHeight + L.inspectorClosedHeight;
  const budgetOpen = L.chromeHeight + L.inspectorOpenHeight;
  console.log(`  LUMP closed: measured ${lumpClosed} vs budgeted ${budgetClosed} (slack ${budgetClosed - lumpClosed})`);
  console.log(`  LUMP open:   measured ${lumpOpen} vs budgeted ${budgetOpen} (slack ${budgetOpen - lumpOpen})`);
  // The constants are meant to be slight OVER-estimates: an over-estimate
  // costs a row, an under-estimate overflows the card. A large over-estimate
  // is its own (milder) bug, so bound both sides.
  ck("closed-state budget is an OVER-estimate of the drawn chrome",
    lumpClosed <= budgetClosed + 0.5, `measured ${lumpClosed} > budgeted ${budgetClosed}`);
  ck("closed-state budget is not wasteful (within 40 pt)",
    budgetClosed - lumpClosed <= 40, `slack ${budgetClosed - lumpClosed}`);
  ck("open-state budget is an OVER-estimate of the drawn chrome+inspector",
    lumpOpen <= budgetOpen + 0.5, `measured ${lumpOpen} > budgeted ${budgetOpen}`);
  ck("open-state budget is not wasteful (within 40 pt)",
    budgetOpen - lumpOpen <= 40, `slack ${budgetOpen - lumpOpen}`);

  // (3) THE CARD FITS. This is the failure an under-stated constant produces,
  // asserted against the MEASURED window rather than a remembered one.
  for (const m of [closed3, closed6, open3, open20, closed20]) {
    ck(`card fits its ceiling (zones=${m.zones} selected=${m.selected})`,
      m.height <= ceiling + 0.5, `h=${m.height} ceiling=${ceiling}`);
  }

  // (4) THE ROW COUNT THE FIX EXISTS FOR, read off the DRAWN card: the list
  // height is (card height - lump), and the lump is now measured, not assumed.
  const drawnRows = (m, lump) => (m.height - lump + L.rowGap) / (L.rowHeight + L.rowGap);
  const rowsOpen20 = drawnRows(open20, lumpOpen);
  const rowsClosed20 = drawnRows(closed20, lumpClosed);
  const rowsOpen3 = drawnRows(open3, lumpOpen);
  console.log(`  DRAWN ROWS: 20 zones + inspector = ${rowsOpen20.toFixed(2)}`);
  console.log(`  DRAWN ROWS: 20 zones, nothing selected = ${rowsClosed20.toFixed(2)}`);
  console.log(`  DRAWN ROWS: 3 zones + inspector = ${rowsOpen3.toFixed(2)}`);
  ck(`inspector open shows ${L.maxRowsWithInspector} rows, not the ~1.7 of the defect`,
    Math.abs(rowsOpen20 - L.maxRowsWithInspector) <= 0.1, `drawn=${rowsOpen20.toFixed(2)}`);
  ck(`nothing selected shows ${L.maxRowsWithoutInspector} rows`,
    Math.abs(rowsClosed20 - L.maxRowsWithoutInspector) <= 0.1, `drawn=${rowsClosed20.toFixed(2)}`);
  ck("a 3-zone library draws 3 rows, not a padded well",
    Math.abs(rowsOpen3 - 3) <= 0.1, `drawn=${rowsOpen3.toFixed(2)}`);

  // (5) The arithmetic the view runs must agree with the pixels it produced.
  const predictedOpen20 = lumpOpen + zoneListHeight(20, true, avail);
  ck("layout function predicts the drawn height (20 zones + inspector)",
    Math.abs(open20.height - predictedOpen20) <= 1,
    `drawn=${open20.height} predicted=${predictedOpen20}`);

  // (6) SPLITTING THE LUMP — the measurement that actually matters.
  //
  // Overflow depends on `chromeHeight` ALONE, not on the pair: when the
  // inspector is CLAMPED its height IS `inspectorRoom`, so
  //   card = chrome_real + list + (ceiling - chromeHeight - list)
  //        = ceiling + (chrome_real - chromeHeight)
  // and the card's overshoot IS the chrome constant's error, directly. A tall
  // window never clamps (the inspector hugs), so squeeze the window to its
  // floor — which is also the worst case the card must survive.
  const wf = await cmd("debug.windowFrame", { height: 200 }); // clamps to the floor
  console.log(`  window squeezed to content height ${wf.result?.height} (floor ${wf.result?.minHeight})`);
  const tight = await measure(20, true);
  console.log(`  measured TIGHT zones=20 selected=true -> h=${tight.height} avail=${tight.avail}`);
  const tightCeiling = cardCeiling(tight.avail);
  const tightRoom = tightCeiling - L.chromeHeight - zoneListHeight(20, true, tight.avail);
  const clamped = tightRoom < lumpOpen - L.chromeHeight; // room < inspector's natural height
  ck("the squeezed window really does CLAMP the inspector (else this measures nothing)",
    clamped, `room=${tightRoom} inspectorNatural≈${(lumpOpen - L.chromeHeight).toFixed(1)}`);
  const chromeReal = tight.height - tightCeiling + L.chromeHeight;
  const inspectorReal = lumpOpen - chromeReal;
  console.log(`  SPLIT: chrome_real=${chromeReal.toFixed(1)} (constant ${L.chromeHeight}) · `
    + `inspectorOpen_real=${inspectorReal.toFixed(1)} (constant ${L.inspectorOpenHeight})`);
  ck("chromeHeight OVER-estimates the drawn chrome (this is what prevents overflow)",
    chromeReal <= L.chromeHeight + 0.5, `chrome_real=${chromeReal.toFixed(1)} > ${L.chromeHeight}`);
  ck("inspectorOpenHeight OVER-estimates the drawn inspector",
    inspectorReal <= L.inspectorOpenHeight + 0.5,
    `inspector_real=${inspectorReal.toFixed(1)} > ${L.inspectorOpenHeight}`);
  ck("card fits its ceiling at the WINDOW FLOOR (the worst case)",
    tight.height <= tightCeiling + 0.5, `h=${tight.height} ceiling=${tightCeiling}`);
  ck(`zone list holds its ${L.minVisibleRows}-row floor at the window floor`,
    Math.abs(zoneListHeight(20, true, tight.avail) - rowsHeight(L.minVisibleRows)) <= 0.5,
    `list=${zoneListHeight(20, true, tight.avail)}`);
  const tightShot = await cmd("debug.captureUI", { path: `${SCRATCH}/m26i-h-tight.png` });
  ck("window-floor state CAPTURED", tightShot.ok, tightShot.error);
  await cmd("debug.windowFrame", { width: 1440, height: 900 });

  // Captures for a human (and for me) to COUNT rows in, rather than derive.
  await cmd("debug.explainMode", { on: false });
  r = await cmd("debug.samplerEditor", { close: true });
  await cmd("track.setInstrument", { trackId, kind: "sampler", sampler: { zones: library(20) } });
  await cmd("debug.samplerEditor", { open: true, trackId });
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m26i-h-20-closed.png` });
  ck("20 zones, no selection CAPTURED", r.ok, r.error);
  const desc = await cmd("instrument.describeSampler", { trackId, offset: 0, limit: 1 });
  await cmd("debug.samplerEditor", { zoneId: desc.result?.zones?.[0]?.id });
  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m26i-h-20-open.png` });
  ck("20 zones + inspector CAPTURED", r.ok, r.error);

  console.log(`M26I_HEIGHT pass=${pass} fail=${fail}`);
} catch (e) {
  fail++;
  console.log(`FAIL exception :: ${e.stack}`);
} finally {
  try { ws?.close(); } catch { /* ignore */ }
  stopStaging(GATE); // SIGTERM by EXACT pid from the pidfile; never pkill
  console.log("staging stopped (pidfile-exact)");
}
process.exit(fail === 0 ? 0 : 1);
